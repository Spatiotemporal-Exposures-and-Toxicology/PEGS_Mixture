source("./R/load_packages.r")

# unzip to nc
targets <- "./input/noaa_hms"
# zips <- list.files(path = paste0(dpath, "/raw"), pattern = "*.zip$", full.names = TRUE)
# targets <- paste0(dpath)
# invisible(sapply(zips, unzip, exdir = targets))

filedates <- gsub("*.*hms_smoke_Shapefile_", "", zips)
filedates <- gsub("\\.(zip)", "", filedates)
filedates <- as.Date(filedates, format = "%Y%m%d")

shps <- list.files(path = targets, pattern = "*.shp$", full.names = TRUE, recursive = TRUE)
# version: by density
# version: by total extent (union)
# single worker to process single file
worker_density <- function(path, time = NULL,
  sub_dens = "Heavy", template = baserast) {
  # parse time
  smoke <- terra::vect(path)
  smoke <- terra::project(smoke, "EPSG:5070")
  # smoke$Density <- factor(smoke$Density, levels = c("Heavy", "Medium", "Light"))
  # smoke <- smoke[order(smoke$Density, smoke$End),]
  formattext <- "%Y%j %H%M"
  smoke$time_start <- as.POSIXct(smoke$Start, format = formattext)
  smoke$time_end <- as.POSIXct(smoke$End, format = formattext)
  smoke$timediff_h <- (as.numeric(smoke$time_end) - as.numeric(smoke$time_start)) / 3600
  smoke <- smoke[smoke$Density == sub_dens, ]
  smoke_r <- terra::rasterize(smoke, template, field = "timediff_h")
  return(smoke_r)
}


worker_all <- function(path, time, template = baserast) {
  # parse time
  smoke <- terra::vect(path)
  smoke <- terra::project(smoke, "EPSG:5070")
  smoke <- smoke[order(smoke$Density, smoke$Start), ]
  smoke <- terra::aggregate(smoke)
  smoke <- terra::buffer(smoke, 0)
  smoke$presence <- 1
  smoke_r <- terra::rasterize(smoke, template, "presence")
  return(smoke_r)
}


# blank raster
target_ext <-
  terra::vect(terra::ext(c(-127, -70, 22, 50)),
    crs = "EPSG:4326") |>
  terra::project("EPSG:5070")


baserast <- terra::rast(
  extent = target_ext,
  resolution = 4e3L,
  crs = "EPSG:5070"
)

targrasts <- gsub("raw/hms_smoke_Shapefile", "processed_heavy/smoke_heavy", zips)
targrasts <- gsub("zip", "nc", targrasts)

plan(multicore, workers = 8)
doFuture::registerDoFuture()
foreach(
  x = seq_along(shps),
  .export = c("baserast", "zips", "shps", "targrasts", "worker_density"),
  .packages = c("dplyr", "terra")
) %dopar% {
  pcs <- worker_density(shps[x], template = baserast)
  terra::writeRaster(pcs, filename = targrasts[x], overwrite = TRUE)
}

targrasts <- gsub("raw/hms_smoke_Shapefile", "processed_medium/smoke_medium", zips)
targrasts <- gsub("zip", "nc", targrasts)

foreach(
  x = seq_along(shps),
  .export = c("baserast", "zips", "shps", "targrasts", "worker_density"),
  .packages = c("dplyr", "terra")
) %dopar% {
  pcs <- worker_density(shps[x], template = baserast, sub_dens = "Medium")
  terra::writeRaster(pcs, filename = targrasts[x], overwrite = TRUE)
}

targrasts <- gsub("raw/hms_smoke_Shapefile", "processed_light/smoke_light", zips)
targrasts <- gsub("zip", "nc", targrasts)

foreach(
  x = seq_along(shps),
  .export = c("baserast", "zips", "shps", "targrasts", "worker_density"),
  .packages = c("dplyr", "terra")
) %dopar% {
  pcs <- worker_density(shps[x], template = baserast, sub_dens = "Light")
  terra::writeRaster(pcs, filename = targrasts[x], overwrite = TRUE)
}


## regardless of density

targrasts <- gsub("raw/hms_smoke_Shapefile", "processed_all/hms_smoke", zips)
targrasts <- gsub("zip", "nc", targrasts)

foreach(
  x = seq_along(shps),
  .export = c("baserast", "zips", "shps", "targrasts", "worker_all"),
  .packages = c("dplyr", "terra")
) %dopar% {
  pcs <- worker_all(shps[x], template = baserast)
  terra::writeRaster(pcs, filename = targrasts[x], overwrite = TRUE)
}

# kk <- shps[1136]
# kkv <- vect(kk)
# kkva <- aggregate(kkv)
# kkvs <- kkv[order(kkv$Density, kkv$Start), ]
# kkvsa <- aggregate(kkvs)
# kkvsa$presence <- 1
# plot(kkvsa)

# testcode
test <- worker_density(shps[1])
plot(test)

test1 <- lapply(shps[1:100], worker_density, sub_dens = "Light")
test1m <- do.call(c, test1)
plot(test1m[,,80:95])


ff <- terra::vect(shps[124])
tf <- "%Y%j %H%M"
indx <- 7
dd <- as.POSIXct(ff$Start[indx], format = tf)
de <- as.POSIXct(ff$End[indx], format = tf)
unclass(de-dd)
diff(de, dd)



### spatiotemporal query
## 1. make virtual raster
target_heavy <- paste0(dpath, "/processed_heavy/")
paths_heavy <-
  list.files(
    path = target_heavy,
    pattern = "*.nc$",
    full.names = TRUE)
paths_heavy

system(sprintf("gdalbuildvrt -separate %ssmoke_14yr.vrt %s*.nc", target_heavy, target_heavy))

heavy_vrt <- terra::rast(paste0(target_heavy, "smoke_14yr.vrt"))
time(heavy_vrt) <- filedates

heavy_vrt

heavy_vrt[terra::time(heavy_vrt) > as.Date("2018-04-30")]




### 2. instant query


## instant query from data
query_instant <-
  function(
    loc = NULL,
    dir = "./input/noaa_hms/processed_heavy/",
    filevect = NULL,
    date_at = "2020-12-31",
    days_before = 50L
  ) {
    date_at <- as.Date(date_at)
    date_start <- date_at - days_before
    date_range <- seq(date_start, date_at, 1)
    date_range_str <- gsub("-", "", as.character(date_range))

    if (is.null(filevect)) {
      filevect <- list.files(dir, "*.nc$", full.names = TRUE)
    }
    if (!methods::is(loc, "SpatVector")) {
      try(loc <- terra::vect(loc))
    }
    # date_at_str <- gsub("-", "", date_at)
    # date_start_str <- gsub("-", "", date_start)

    # locbuf <- terra::buffer(loc, 8000, capstyle = "square")
    locbuf <- terra::ext(loc) + 4000
    filevect_sub <-
      grep(paste0("(",
                  paste(date_range_str, collapse = "|"),
                  ")"),
           filevect, value = TRUE)
    targets <-
      Reduce(c,
             sapply(filevect_sub, \(x) terra::rast(x, win = locbuf)))

    #res_mean <- terra::extract(targets, loc, na.rm = TRUE)
    res_sum <- sum(terra::extract(targets, loc, na.rm = TRUE), na.rm = TRUE)
    res <- data.frame(sum = res_sum)
    names(res) <- paste0("smoke_", sprintf("%03ddays", days_before))
    return(res)
  }

test_loc <-
  terra::vect(matrix(c(-120, 42), ncol = 2),
              crs = terra::crs("EPSG:4326"))
test_loc <- terra::project(test_loc, "EPSG:5070")
query_instant(test_loc, filevect = NULL, date_at = "2021-11-01")
query_instant(
  test_loc,
  dir = "~/Documents/input/noaa_hms/processed_all/",
  date_at = "2010-10-01",
  days_before = 56L)

# small test:
epr_allp_sf_ea <-
  epr_allp_sf %>%
  dplyr::mutate(gis_event_date = as.Date(gis_event_date, format = "%m/%d/%Y")) %>%
  dplyr::filter(gis_study_event == "current_address_exposome_a") %>%
  dplyr::filter(!gis_state %in% c("HI", "AK", "GU", "VI", "PR")) %>%
  dplyr::filter(!is.na(gis_event_date)) %>%
  sf::st_transform("EPSG:5070")

library(future)
plan(multicore, workers = 50)

epr_ea_smokeextract <- function(days_before = 60L, dir = "./input/noaa_hms/processed_heavy/") {
  future.apply::future_mapply(function(x, y) {
    unlist(query_instant(
    x,
    dir = dir,
    date_at = as.Date(y),
    days_before = days_before)) },
    split(terra::vect(epr_allp_sf_ea$geometry), seq_len(nrow(epr_allp_sf_ea))),
    split(epr_allp_sf_ea$gis_event_date, seq_len(nrow(epr_allp_sf_ea))))
}

epr_allp_ea_v <- vect(epr_allp_sf_ea)
epr_allp_ea_v$smoke_h90d <- smoke_days_h90d
plot(epr_allp_ea_v, "smoke_h120d", col = RColorBrewer::brewer.pal(50, "Reds"), type = "continuous")
plot(epr_allp_ea_v, "smoke_h90d", col = RColorBrewer::brewer.pal(50, "Reds"), type = "continuous")

smoke_all_60d <- readRDS("output/smoke_days_60days_ea_nona_addr.rds")
smoke_all_365d <- readRDS("output/smoke_days_365days_ea_nona_addr.rds")
epr_allp_ea_v$smoke_a60d <- smoke_all_60d
epr_allp_ea_v$smoke_a365d <- smoke_all_365d
plot(epr_allp_ea_v, "smoke_a60d", col = RColorBrewer::brewer.pal(50, "Reds"), type = "continuous")
plot(epr_allp_ea_v, "smoke_a365d", col = RColorBrewer::brewer.pal(50, "Reds"), type = "continuous")


smoke_days_30d <- epr_ea_smokeextract(30L)
saveRDS(smoke_days_30d, "output/smoke_days_30days_ea_nona_addr.rds")
smoke_days_60d <- epr_ea_smokeextract(60L)
saveRDS(smoke_days_60d, "output/smoke_days_60days_ea_nona_addr.rds")
smoke_days_120d <- epr_ea_smokeextract(120L)
saveRDS(smoke_days_120d, "output/smoke_days_120days_ea_nona_addr.rds")
smoke_days_365d <- epr_ea_smokeextract(365L)
saveRDS(smoke_days_365d, "output/smoke_days_365days_ea_nona_addr.rds")


smoke_days_h30d <- epr_ea_smokeextract(30L)
saveRDS(smoke_days_h30d, "output/smoke_days_high_30days_ea_nona_addr.rds")
smoke_days_h60d <- epr_ea_smokeextract(60L)
saveRDS(smoke_days_h60d, "output/smoke_days_high_60days_ea_nona_addr.rds")
smoke_days_h90d <- epr_ea_smokeextract(90L)
saveRDS(smoke_days_h90d, "output/smoke_days_high_90days_ea_nona_addr.rds")
smoke_days_h120d <- epr_ea_smokeextract(120L)
saveRDS(smoke_days_h120d, "output/smoke_days_high_120days_ea_nona_addr.rds")
smoke_days_h150d <- epr_ea_smokeextract(150L)
saveRDS(smoke_days_h150d, "output/smoke_days_high_150days_ea_nona_addr.rds")
smoke_days_h180d <- epr_ea_smokeextract(180L)
saveRDS(smoke_days_h180d, "output/smoke_days_high_180days_ea_nona_addr.rds")
smoke_days_h365d <- epr_ea_smokeextract(365L)
saveRDS(smoke_days_h365d, "output/smoke_days_high_365days_ea_nona_addr.rds")


smoke_days_m30d <- epr_ea_smokeextract(30L, dir = "./input/noaa_hms/processed_medium/")
saveRDS(smoke_days_m30d, "output/smoke_days_medium_30days_ea_nona_addr.rds")
smoke_days_m60d <- epr_ea_smokeextract(60L, dir = "./input/noaa_hms/processed_medium/")
saveRDS(smoke_days_m60d, "output/smoke_days_medium_60days_ea_nona_addr.rds")
smoke_days_m90d <- epr_ea_smokeextract(90L, dir = "./input/noaa_hms/processed_medium/")
saveRDS(smoke_days_m90d, "output/smoke_days_medium_90days_ea_nona_addr.rds")
smoke_days_m120d <- epr_ea_smokeextract(120L, dir = "./input/noaa_hms/processed_medium/")
saveRDS(smoke_days_m120d, "output/smoke_days_medium_120days_ea_nona_addr.rds")
smoke_days_m150d <- epr_ea_smokeextract(150L, dir = "./input/noaa_hms/processed_medium/")
saveRDS(smoke_days_m150d, "output/smoke_days_medium_150days_ea_nona_addr.rds")
smoke_days_m180d <- epr_ea_smokeextract(180L, dir = "./input/noaa_hms/processed_medium/")
saveRDS(smoke_days_m180d, "output/smoke_days_medium_180days_ea_nona_addr.rds")
smoke_days_m365d <- epr_ea_smokeextract(365L, dir = "./input/noaa_hms/processed_medium/")
saveRDS(smoke_days_m365d, "output/smoke_days_medium_365days_ea_nona_addr.rds")



saveRDS(smoke_days_30d, "output/smoke_days_30days_ea_nona_addr.rds")

# in-place code example: failed
epr_allp_sf_ea <-
  epr_allp_sf %>%
  dplyr::filter(gis_study_event == "current_address_exposome_a") %>%
  sf::st_transform("EPSG:5070") %>%
  dplyr::rowwise() %>%
  dplyr::mutate(
    smoke_days_1yr = unlist(query_instant(
    terra::vect(geometry),
    dir = "~/Documents/input/noaa_hms/processed_all/",
    date_at = as.Date(gis_event_date),
    days_before = 30L)))



## starting from nc
targets <- "./input/noaa_hms"
ncs <-
  list.files(targets,
             pattern = "*.nc$",
             recursive = TRUE,
             full.names = TRUE)
ncs_heavy <- grep("heavy", ncs, value = TRUE)
ncs_medium <- grep("medium", ncs, value = TRUE)


