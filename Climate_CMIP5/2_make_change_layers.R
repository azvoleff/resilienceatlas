library(rgdal)
library(raster)
library(dplyr)
library(foreach)
library(stringr)
library(doParallel)

print('Setting up...')
timestamp()

source('../0_settings.R')

source('../ec2/s3_ls.R')

source('../ec2/s3_writeRaster.R')

source('../ec2/get_cluster_hosts.R')
cl <- makeCluster(rep(get_cluster_hosts(), each=4))
registerDoParallel(cl)

s3_in <- 's3://ci-vsdata/CMIP5/seasonal_totals/'
s3_out <- 's3://ci-vsdata/CMIP5/results/'

#Sys.setenv(AWS_CONFIG_FILE='C:/Users/azvol/.aws/config')
s3_files <- s3_ls(s3_in)

s3_files$scenario <- str_extract(s3_files$file, '(historical)|(rcp(45|85))')
s3_files$variable <- str_extract(s3_files$file, '^[a-z]*')
s3_files$season <- str_extract(s3_files$file, '(?<=_)[a-zA-Z]*(?=_((sum)|(mean)))')
s3_files$model <- str_extract(s3_files$file, '(?<=_)[-a-zA-Z0-9]*(?=_[0-9]{4})')
s3_files$year <- as.numeric(str_extract(s3_files$file, '(?<=_)[0-9]{4}(?=_)'))

s3_files$agg_period <- NA
s3_files$agg_period[s3_files$year >= 1986 & s3_files$year <= 2005] <- '1986-2005'
s3_files$agg_period[s3_files$year >= 2040 & s3_files$year <= 2059] <- '2040-2059'
s3_files$agg_period[s3_files$year >= 2080 & s3_files$year <= 2099] <- '2080-2099'

###############################################################################
### Testing
# s3_files <- filter(s3_files, season == 'annual')
# this_variable <- 'pr'
# this_season <- 'annual'
# this_model <- 'ACCESS1-0'
###############################################################################

aws_cp <- function(from, to) {
    system2('aws', args=c('s3', 'cp', from, to, '--region=us-east-1'), stdout=NULL)
}

print('Processing...')
timestamp()
foreach(this_variable=unique(s3_files$variable)) %:%
    foreach(this_season=unique(s3_files$season),
            .packages=c('raster', 'dplyr', 'foreach', 'rgdal')) %dopar% {

    these_files <- filter(s3_files, variable == this_variable,
                          season == this_season)

    base_files <- filter(these_files, scenario == 'historical')
    stopifnot(length(unique(base_files$agg_period)) == 1)
    base_agg_period <- base_files$agg_period[1]

    # Calculate baseline mean (base_m)
    base_m <- foreach(this_model=unique(base_files$model), .combine=stack) %do% {
        temp_dir <- get_tempdir()
        these_base_files <- filter(base_files, model == this_model)$file
        foreach(this_file=these_base_files) %do% {
            aws_cp(paste0(s3_in, this_file), temp_dir)
        }
        model_data <- stack(file.path(temp_dir, these_base_files))
        mod_mean <- mean(model_data)
        unlink(temp_dir, recursive=TRUE)
        return(mod_mean)
    }
    s3_out_base_m <- paste0(s3_out, paste(this_variable, 'historical', 
        base_agg_period, this_season, 'modelmeans.tif', sep='_'))
    s3_writeRaster(base_m, s3_out_base_m)

    # Calculate multimodel mean for baseline (base_mmm)
    s3_out_base_mmm <- paste0(s3_out, paste(this_variable, 'historical', 
        base_agg_period, this_season, 'multimodelmean.tif', sep='_'))
    temp_file <- tempfile(fileext='.tif')
    base_mmm <- calc(base_m, mean, filename=temp_file)
    aws_cp(temp_file, s3_out_base_mmm)

    # Calculate multimodel sd for baseline (base_mmsd)
    s3_out_base_mmsd <- paste0(s3_out, paste(this_variable, 'historical', 
        base_agg_period, this_season, 'multimodelsd.tif', sep='_'))
    temp_file <- tempfile(fileext='.tif')
    base_mmsd <- calc(base_m, sd, filename=temp_file)
    aws_cp(temp_file, s3_out_base_mmsd)

    # Calculate scenario model means
    scenarios <- unique(these_files$scenario[these_files$scenario != 'historical'])
    agg_periods <- unique(these_files$agg_period[these_files$scenario != 'historical'])
    foreach(this_scenario=scenarios) %:% 
        foreach(this_agg_period=agg_periods,
                .packages=c('raster', 'dplyr', 'foreach')) %do% {

        scen_files <- filter(these_files,
                             scenario == this_scenario,
                             agg_period == this_agg_period)

        scen_m <- foreach(this_model=unique(scen_files$model), .combine=stack) %do% {
            temp_dir <- get_tempdir()
            these_scen_files <- filter(scen_files, model == this_model)$file
            foreach(this_file=these_scen_files) %do% {
                aws_cp(paste0(s3_in, this_file), temp_dir)
            }
            model_data <- stack(file.path(temp_dir, these_scen_files))
            mod_mean <- mean(model_data)
            unlink(temp_dir, recursive=TRUE)
            return(mod_mean)
        }
        s3_out_scen_m <- paste0(s3_out, paste(this_variable, this_scenario, 
            this_agg_period, this_season, 'modelmeans.tif', sep='_'))
        s3_writeRaster(scen_m, s3_out_scen_m)

        # Calc scenario multimodel mean
        temp_file <- tempfile(fileext='.tif')
        scen_mmm <- calc(scen_m, mean, filename=temp_file)
        s3_out_scen_mmm <- paste0(s3_out, paste(this_variable, this_scenario, 
                                            this_agg_period, this_season, 
                                            'multimodelmean.tif', sep='_'))
        aws_cp(temp_file, s3_out_scen_mmm)

        # Calc scenario multimodel sd
        temp_file <- tempfile(fileext='.tif')
        scen_mmsd <- calc(scen_m, mean, filename=temp_file)
        s3_out_scen_mmsd <- paste0(s3_out, paste(this_variable, this_scenario, 
                                            this_agg_period, this_season, 
                                            'multimodelsd.tif', sep='_'))
        aws_cp(temp_file, s3_out_scen_mmsd)

        temp_file <- tempfile(fileext='.tif')
        absdiff <- overlay(scen_mmm, base_mmm, fun=function(scen, base) {
                scen - base
            }, filename=temp_file)
        s3_out_diff <- paste0(s3_out, paste(this_variable, this_scenario,
            'absdiff', base_agg_period, 'vs', this_agg_period, this_season, 
            sep='_'), '.tif')
        aws_cp(temp_file, s3_out_diff)

        # Also calculate percent difference for precipitation
        if (this_variable == 'pr') {
            temp_file <- tempfile(fileext='.tif')
            pct_diff <- overlay(scen_mmm, base_mmm, fun=function(scen, base) {
                    ((scen - base) / base) * 100
                }, filename=temp_file)
            s3_out_pctdiff <- paste0(s3_out, paste(this_variable, this_scenario,
                'pctdiff', base_agg_period, 'vs', this_agg_period, 
                this_season, sep='_'), '.tif')
            aws_cp(temp_file, s3_out_pctdiff)
        }
    }
}
print("Finished processing.")
timestamp()
