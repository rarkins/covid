download_latest_fhm <- function(folder = file.path("data", "FHM")) {
    require(readxl)

    DL <- download.file("https://www.arcgis.com/sharing/rest/content/items/b5e7488e117749c19881cce45db13f7e/data",
                        destfile = file.path(folder, "FHM_latest.xlsx"), method = "curl", extra = c("-L"), quiet = TRUE)
    if (DL != 0) { stop("File download error.") }

    # Check archived files for latest record
    latest_record <- max(as.Date(gsub("^.*(2020-[0-9]{2}-[0-9]{2}).xlsx", "\\1", list.files(folder, pattern = "^Folkhalso"))))

    # Check if new download is newer than latest record, in that case, archive it.
    new_record <- get_record_date(file.path(folder, "FHM_latest.xlsx"))

    if (latest_record < new_record) {
        file.copy(file.path(folder, "FHM_latest.xlsx"),
                  file.path("data", "FHM", paste0("Folkhalsomyndigheten_Covid19_", new_record, ".xlsx")))
    }
}

get_remote_data <- function(url, f) {
    require(curl)
    require(data.table)

    DT <- fread(url)
    fwrite(DT, f)
    return(DT)
}

get_ecdc <- function(url, f) {
    require(curl)
    require(data.table)

    DT <- tryCatch({
        DT <- fread(url)
        fwrite(DT, f)
        return(DT)
    }, error = function(cond) {
        warning("ECDC get_remote data error")
        return(fread(f))
    })

    return(DT)
}

get_record_date <- function(f) {
    sheets <- excel_sheets(f)
    ret <- as.Date(sub("^FOHM ", "", sheets[length(sheets)]), format="%d %b %Y")
    if (is.na(ret)) ret <- as.Date(sub("^FOHM ", "", sheets[grep("FOHM", sheets)]), format="%d %b %Y")
    if (length(ret) > 0) return(ret)
    return(as.Date(NA))
}

trigger_new_download <- function(f) {
    require(data.table)

    if (!file.exists(f)) {
        return(TRUE)
    }

    latest_record <- get_record_date(f)

    if (latest_record < Sys.Date()) {
        if (as.ITime(Sys.time(), tz = "Europe/Stockholm") > as.ITime("14:00")) {
            return(TRUE)
        }
    }

    return(FALSE)
}

list_fhm_files <- function(folder = file.path("data", "FHM")) {
    list.files(folder, pattern = "^Folkhalso", full.names = TRUE)
}

load_fhm_data <- function(f, type) { # type %in% c("deaths", "icu")
    require(data.table)
    require(readxl)
    require(stringr)
    require(lubridate)

    publication_date <- get_record_date(f)
    file_date <- as.Date(str_extract(f, "[0-9]{4}-[0-9]{2}-[0-9]{2}"))

    if (is.na(publication_date)) {
        publication_date <- file_date
    } else {
        if (publication_date != file_date) { warning("Pub date not file date: [", f, "].") }
    }

    # Skip early reports that do not contain death data
    if (type == "deaths") start_date <- as.Date("2020-04-01")
    if (type == "icu") start_date <- as.Date("2020-04-24")
    if (publication_date <= start_date) return(NULL)

    if (type == "deaths") sheet_n <- 2
    if (type == "icu") {
        sheets <- excel_sheets(f)
        sheet_n <- grep("intensivvårdade", sheets)
    }

    DT <- data.table((
        read_excel(path = f, sheet = sheet_n, col_types = c("text", "numeric"))
    ))

    setnames(DT, c("date", "N"))
    DT[(tolower(date) %in% c("uppgift saknas", "uppgift saknaa", "uppgift saknas+a1")), date := NA]

    if (can_be_numeric(DT[, date])) {
        DT[, date := as.Date(as.numeric(date), origin = "1899-12-30")]
    } else {
        DT[, date := as.Date(date)]
    }

    # Ensure starting point is March 1st, and that all dates have a value
    # date_seq <- seq.Date(as.Date("2020-03-01"), publication_date, by = 1)
    date_seq <- tryCatch({
        seq.Date(as.Date("2020-03-01"), publication_date, by = 1)
    }, error = function(cond) {
        browser()
        print(publication_date)
        stop("Error: ", cond, "[", f, "]")
    })

    DT <- merge(DT, data.table(date = date_seq), all = TRUE)
    DT[is.na(N), N := 0]
    DT[, publication_date := publication_date]
    setkey(DT, publication_date, date)

    return(as.data.frame(DT))
}

can_be_numeric <- function(x) {
    # Check if vector can be converted to numeric
    stopifnot(is.atomic(x) || is.list(x)) # check if x is a vector
    numNAs <- sum(is.na(x))
    numNAs_new <- suppressWarnings(sum(is.na(as.numeric(x))))
    return(numNAs_new == numNAs)
}

join_data <- function(death_dts) {
    death_dt <- data.table(death_dts)
    setkey(death_dt, publication_date, date)

    death_dt[!is.na(date) & publication_date > "2020-04-02", days_since_publication := publication_date - date]
    death_dt[date == "2020-04-02" & publication_date == "2020-04-02", days_since_publication := 0]

    death_dt[!is.na(date), paste0("n_m", 1) := shift(N, n = 1, type = "lag", fill = 0L), by = date]
    death_dt[!is.na(date), n_diff := N - n_m1]
    death_dt[!is.na(date) & n_m1 > 0 & !is.na(n_m1), n_diff_pct := N/n_m1 - 1]
    death_dt[!is.na(date) & n_m1 == 0 & N == 0, n_diff_pct := 0]
    death_dt[, n_m1 := NULL]

    # Categorize by grouped days since publication.
    # 1, 2, ... > 1 week, 2 weeks
    death_dt[, delay := as.numeric(days_since_publication)]
    death_dt[delay >= 14, delay := 14]
    death_dt[delay >= 7 & delay < 14, delay := 7]
    death_dt[is.na(delay), delay := -1]
    death_dt[, delay := factor(delay,
                               levels = c(-1, 0, 1, 2, 3, 4, 5, 6, 7, 14),
                               labels = c("No Data", "Same day", "1 Day", "2 Days",
                                          "3-4 Days", "3-4 Days", "5-6 Days",
                                          "5-6 Days", "7-13 Days", "14 Days +"))]

    return(death_dt)
}

predict_lag <- function(death_dt) {
    # Calculate the average lag from the last 14 days for each report
    # So when calculating the average number of deaths added on day 3,
    # include day-3 reports from two weeks back from that date.
    DT <- death_dt[days_since_publication != 0 &
                   !is.na(days_since_publication) &
                   !is.na(date) &
                   date >= "2020-04-02",
                   .(date, publication_date, days_since_publication, n_diff)]

    # Create predictions for each publication date so we can track and evaluate
    # historical predictions
    report_dates <- seq(as.Date("2020-04-14"), death_dt[, max(publication_date)], 1)
    dts <- vector(mode = "list", length = length(report_dates))
    for (i in seq_along(report_dates)) {
        avg_delay <- DT[publication_date <= report_dates[i]]

        # For each delay day, calculate the mean additional deaths added
        # for the two weeks of reports preceding that date.
        # --> If we are calculating deaths added 7 days after, we look at
        #     deaths added 1 week ago back to deaths added 3 weeks ago.
        #     This way, we always take the mean of 2 weeks of reports (when available).
        avg_delay[, ref_date := max(date), by = days_since_publication]
        dts[[i]] <- avg_delay[date %between% list(ref_date - 14, ref_date),
                              .(avg_diff = mean(n_diff, na.rm = TRUE),
                                sd_diff = sd(n_diff, na.rm = TRUE)),
                              by = days_since_publication]
    }

    names(dts) <- report_dates
    avg_delay <- rbindlist(dts, idcol = "publication_date")
    avg_delay[, publication_date := as.Date(publication_date)]

    setkey(avg_delay, publication_date, days_since_publication)

    # To create actual predictions of totals per day
    # we need to add the averages to the reported data
    predictions <- avg_delay[death_dt[date >= "2020-04-02" & publication_date >= "2020-04-14"],
              on = .(publication_date,
                     days_since_publication > days_since_publication),
              by = .EACHI,
              .(date,
                sure_deaths = N,
                predicted_deaths = sum(avg_diff, na.rm = TRUE),
                predicted_deaths_SD = sqrt(sum(sd_diff^2, na.rm = TRUE)))] # assuming independently normal

    setnames(predictions, "publication_date", "prediction_date")
    predictions[, total := sure_deaths + predicted_deaths]

    # CIs
    predictions[, total_lCI := total - 1.96 * predicted_deaths_SD]
    predictions[, total_uCI := total + 1.96 * predicted_deaths_SD]
    predictions[, predicted_deaths_SD := NULL]

    # Assume no more deaths after 28 days just to have a cleaner data set
    predictions <- predictions[days_since_publication <= 30]
    predictions[, days_since_publication := NULL]

    setkey(predictions, prediction_date, date)

    return(predictions)
}

calculate_lag <- function(death_dt, thresholds = c(0, 0.01, 0.02, 0.05, 0.10)) {
    # Count as finished when for 3 consecutive days, the daily increase is below threshold
    DT <- copy(death_dt)[!is.na(date) & date >= "2020-04-02"]
    setorder(DT, date, publication_date)

    # Calculate threshold values
    # As max of daily increase over last 3 days
    # DT[!is.na(date), paste0("n_diff_pct_m", 1:3) := shift(n_diff_pct, n = 1:3), by = date]
    # DT[, max_diff := pmax(n_diff_pct, n_diff_pct_m1, n_diff_pct_m2, n_diff_pct_m3, na.rm = TRUE)]
    # DT[!is.na(max_diff), forcing_var := cummin(max_diff), by = date]

    # Or as total 3-day increase
    DT[!is.na(date), paste0("N_m", 3) := shift(N, n = 3), by = date]
    DT[, forcing_var := (N / N_m3) - 1]

    # Often nothing is added in the first days, ensure its not counted as finished
    DT[days_since_publication %in% c(0,1,2,3) & is.na(forcing_var), forcing_var := Inf]

    DT <- DT[, .(publication_date, date, n_diff, forcing_var, days_since_publication)]
    setkey(DT, publication_date, date)

    for (t in thresholds) {
        DT[, finished := FALSE]
        DT[forcing_var <= t, finished := TRUE]

        # Days until finished
        DT[DT[finished == TRUE, min(as.numeric(days_since_publication), na.rm = TRUE), by = date],
           paste0("days_to_finished_", 100 * t) := i.V1, on = .(date)]

        # Rolling average
        DT[, paste0("days_to_finished_", 100 * t, "_avg") :=
            frollmean(get(paste0("days_to_finished_", 100 * t)), 4, algo = "exact", align = "center")]

        # Error (number of deaths added after tagged as finished)
        DT[DT[finished == TRUE, sum(n_diff, na.rm = TRUE), by = date],
           paste0("N_added_after_finished_", 100 * t) := i.V1, on = .(date)]

    }

    DT <- DT[publication_date == max(publication_date, na.rm = TRUE)]
    DT[, c("finished", "n_diff", "forcing_var", "publication_date", "days_since_publication") := NULL]

    setkey(DT, date)
    return(DT)
}

day_of_week <- function(death_dt) {
    # Create day of week markers
    days <- unique(death_dt[!is.na(date), .(date, wd = substr(weekdays(date),1, 1), weekend = FALSE)])
    days[wd %in% c("S", "S"), weekend := TRUE]
    days[date %between% c("2020-04-10", "2020-04-13"), weekend := TRUE]
    days[date == "2020-05-01", weekend := TRUE]
    days[date == "2020-05-21", weekend := TRUE]

    return(days)
}

##
# Plots
set_default_theme <- function() {
    require(ggplot2)
    require(hrbrthemes)

    theme_ipsum(base_family = "EB Garamond") %+replace%
        theme(
            text = element_text(size = 12, color = "#333333", family = "EB Garamond"),
            plot.title = element_text(size = rel(2), face = "plain", hjust = 0, margin = margin(0,0,5,0)),
            plot.subtitle = element_text(size = rel(1), face = "plain", hjust = 0, margin = margin(0,0,5,0)),
            plot.caption = element_text(size = rel(0.7), family = "EB Garamond", face = "italic", hjust = 1, vjust = 1, margin = margin(12,0,0,0)),

            legend.text = element_text(size = rel(0.9), family = "EB Garamond", hjust = 0, margin = margin(0, 0, 0, 0)),
            legend.background = element_rect(fill = "#F5F5F5", color = "#333333"),
            legend.margin = margin(5,5,5,5),
            legend.direction = "vertical",
            legend.position = "right",
            legend.justification = "left",
            legend.box.margin = margin(0,0,0,0),
            legend.box.just = "left",

            axis.title.y = element_text(size = rel(1.2), face = "plain", angle = 90, hjust = 1, vjust = 1, margin = margin(0, 4, 0, 0)),
            axis.title.x = element_text(size = rel(1.2), face = "plain", hjust = 1, vjust = 1, margin = margin(4, 0, 0, 0)),
            axis.text.x = element_text(angle = 35, hjust = 1, vjust = 1.1),

            # Panels
            plot.background = element_rect(fill = "transparent", color = NA),
            # plot.background = element_rect(fill = "#f5f5f5", color = NA), # bg of the plot
            panel.border = element_blank(),
            panel.grid.major.x = element_blank(),
            panel.grid.minor.x = element_blank(),
            panel.grid.major.y = element_line(linetype = "dotted", color = "#CCCCCC", size = 0.3),
            panel.grid.minor.y = element_line(linetype = "dotted", color = "#CECECE", size = 0.2)
        )
}

plot_lagged_deaths <- function(death_dt,
                               death_prediction_constant, death_prediction_model,
                               ecdc, days, default_theme) {
    require(ggplot2)
    require(forcats)

    latest_date <- death_dt[, max(publication_date, na.rm = TRUE)]
    total_deaths <- death_dt[publication_date == latest_date, sum(N, na.rm = TRUE)]

    death_dt <- death_dt[date >= "2020-03-12"]
    death_prediction_constant <- death_prediction_constant[prediction_date == latest_date]
    death_prediction_model <- death_prediction_model[prediction_date == latest_date]

    predicted_deaths <- round(death_prediction_model[, sum(predicted_deaths)], 0)

    # Deaths by actual date
    actual_deaths <- death_dt[publication_date == latest_date & !is.na(date), .(date, N)]
    actual_deaths <- merge(actual_deaths, death_prediction_constant[, .(date, predicted = total)],
                           by = "date", all = TRUE)
    actual_deaths[is.na(predicted), predicted := N]
    setkey(actual_deaths, date)
    actual_deaths[, avg := frollmean(N, 7, algo = "exact", align = "center")]
    actual_deaths[, avg_pred := frollmean(predicted, 7, algo = "exact", align = "center")]

    # ECDC data of reported deaths per day
    # Moving average (centered)
    # ecdc <- ecdc[countryterritoryCode == "SWE",
    #              .(date = as.Date(dateRep, format = "%d/%m/%Y"),
    #                cases, deaths)]
    # ecdc <- ecdc[, date := date - 1]
    # ecdc <- ecdc[date >= "2020-03-12"]
    # setkey(ecdc, date)
    # ecdc[, avg := frollmean(deaths, 7, algo = "exact", align = "center")]

    death_dt[publication_date == "2020-04-02" & is.na(days_since_publication), publication_date := NA]
    date_diff <- death_dt[!is.na(publication_date), sum(n_diff, na.rm = TRUE), by = publication_date]
    death_dt <- death_dt[n_diff != 0 & !is.na(n_diff)]

    # Only one observation per group
    death_dt <- death_dt[, .(n_diff = sum(n_diff, na.rm = TRUE)), by = .(date, delay)]
    levels(death_dt$delay) <- death_dt[, sum(n_diff), delay][order(c(1,2,7,6,5,4,3,8))][, paste0(delay, " (N=", V1, ")")]

    fill_colors <- c("gray40", "#FF0000", "#507159", "#55AC62", "#F2AD00", "#F69100", "#5BBCD6", "#478BAF", "#E1E1E1")
    fill_colors <- setNames(fill_colors, c(levels(death_dt$delay), "Model nowcast"))
    death_dt[, delay := forcats::fct_rev(delay)]
    label_order <- c("Model nowcast", levels(death_dt$delay))

    # Drop earliest data
    death_dt <- death_dt[date >= "2020-03-12"]
    death_prediction_constant <- death_prediction_constant[date >= "2020-03-12"]
    days <- days[date >= "2020-03-12"]

    ggplot(data = death_dt, aes(y = n_diff, x = date)) +
        geom_hline(yintercept = 0, linetype = "solid", color = "#999999", size = 0.4) +
        #geom_bar(data = death_prediction_constant, aes(y = total, fill = "Model nowcast"), stat="identity", width = 1) +
        geom_bar(data = death_prediction_model, aes(y = total, fill = "Model nowcast"), stat="identity", width = 1) +
        geom_bar(position = "stack", stat = "identity", aes(fill = delay), width = 1) +

        # geom_line(data = ecdc[!is.na(avg)], aes(x = date, y = avg, linetype = "By report date"), color = "#444444") +
        # geom_line(data = actual_deaths[!is.na(avg)], aes(x = date, y = avg, linetype = "By death date"), color = "#444444") +
        #geom_line(data = actual_deaths[!is.na(avg_pred)], aes(x = date, y = avg_pred, linetype = "Forecast"), color = "#444444") +

        #geom_line(data = death_prediction_model, aes(x = date, y = total, linetype = "Model forecast"), color = "#444444") +
        # geom_ribbon(data = death_prediction_model, aes(x = date, y = total, ymin = predicted_deaths_lCI, ymax = predicted_deaths_uCI),
        #             fill = "#444444", alpha = 0.2) +
        geom_point(data = death_prediction_model, aes(x = date, y = total_lCI),
                    color = "#000000", fill = "#000000", alpha = 0.4, size = 0.2, shape = 2) +
        geom_point(data = death_prediction_model, aes(x = date, y = total_uCI),
                    color = "#000000", fill = "#000000", alpha = 0.4, size = 0.2, shape = 6) +

        #geom_text(data = days, aes(y = -4, label = wd, color = weekend), size = 2.5, family = "EB Garamond", show.legend = FALSE) +
        annotate(geom = "label", fill = "#F5F5F5", color = "#333333",
                 hjust = 0, family = "EB Garamond",
                 label.r = unit(0, "lines"), label.size = 0.5,
                 x = Sys.Date()-60, y = 100,
                 label = paste0(latest_date, "\n",
                                "Reported: ", format(total_deaths, big.mark = ","), "\n",
                                "Predicted:    ", format(predicted_deaths, big.mark = ","), "\n",
                                "Total:        ", format(total_deaths + predicted_deaths, big.mark = ","))) +
        # scale_color_manual(values = c("black", "red")) +
        scale_fill_manual(values = fill_colors, limits = label_order, drop = FALSE) +
        # scale_linetype_manual(values = c(#"By report date" = "dotted",
        #                                  "By death date" = "solid",
        #                                  "Model forecast" = "dashed"), name = "Statistics") +
        scale_x_date(date_breaks = "1 month", date_labels = "%B", expand = expansion(add = 0)) +
        scale_y_continuous(minor_breaks = seq(0,200,10), breaks = seq(0,200,20), expand = expansion(add = c(0, 10)), sec.axis = dup_axis(name=NULL)) +
        default_theme +
        labs(title = paste0("Confirmed daily Covid-19 deaths in Sweden"),
             subtitle = paste0("Each death is attributed to its actual day of death. Colored bars show reporting delay. Negative values indicate data corrections.\n",
                               "Gray bars show median predictions, with arrows indicating endpoints of 95% credible intervals."),
             caption = paste0("Source: Folkhälsomyndigheten and ECDC. Updated: ", Sys.Date(), ". Latest version available at https://adamaltmejd.se/covid."),
             fill = "Reporting delay",
             x = "Date of death",
             y = "Number of deaths")
}

plot_lag_trends1 <- function(time_to_finished, days, default_theme) {
    DT <- time_to_finished[, c(1, grep("days_to_finished_[0-9]+_avg$", names(time_to_finished))), with = FALSE]
    DT <- melt(DT, id.vars = "date", variable.factor = FALSE)
    DT <- DT[!is.na(value)]

    DT[, variable := factor(as.numeric(gsub("[a-z_]*", "", variable)))]
    levels(DT$variable) <- paste0(levels(DT$variable), "%")

    days <- days[date %between% c(DT[, min(date)], DT[, max(date)])]

    ggplot(data = DT, aes(x = date, y = value)) +
        #geom_text(data = days[weekend == TRUE], aes(y = -1, label = wd), color = "red", size = 2, family = "EB Garamond") +
        #geom_text(data = days[weekend == FALSE], aes(y = -1, label = wd), color = "black", size = 2, family = "EB Garamond") +
        geom_line(aes(group = variable, color = variable), linetype = "twodash", size = 0.9, alpha = 0.8) +
        scale_x_date(date_breaks = "1 month", date_labels = "%B", expand = c(0.02,0.02)) +
        scale_y_continuous(limits = c(-1, 32), expand = expansion(add = c(0, 0)), breaks = c(7, 14, 21, 28), minor_breaks = NULL) +
        # scale_y_continuous(limits = c(0, NA), breaks = c(5, 10, 15, 20), expand = expansion(add = c(0,3))) +
        scale_color_manual(values = wes_palette("Darjeeling2"), guide = guide_legend(title.position = "top")) +
        default_theme +
        theme(legend.direction = "horizontal",
              legend.position = c(0.4, 0.8), legend.justification = "center",
              panel.grid.major.x = element_line(linetype = "dotted", color = "#CCCCCC", size = 0.3),
              panel.grid.minor.x = element_line(linetype = "dotted", color = "#CECECE", size = 0.2)) +
        labs(color = "Completed = days until 3-day change is below:",
             x = "Death date",
             y = 'Days until date is "completed"')
}

plot_lag_trends2 <- function(death_dt, days, default_theme) {
    DT <- copy(death_dt)

    DT <- DT[n_diff > 0 & publication_date > "2020-04-02"]
    DT[, lag := as.numeric(days_since_publication)]

    DT[, perc90_days := quantile(rep(lag, times = n_diff), probs = c(0.90)), by = publication_date]

    colors <- c("#FF0000", "#507159", "#55AC62", "#F2AD00", "#F69100", "#5BBCD6", "#478BAF", "#FF0000", "#000000")
    names <- c(levels(DT$delay)[!grepl("No Data", levels(DT$delay))], "Weekend", "Weekday")
    colors <- setNames(colors, names)
    DT[, delay := forcats::fct_rev(delay)]
    label_order <- c(levels(DT$delay)[!grepl("No Data", levels(DT$delay))], "Weekend", "Weekday")

    g <- ggplot(data = DT[lag <= 30],
                aes(x = publication_date, y = lag)) +
        #geom_text(data = days[weekend == TRUE & date > "2020-04-02"], aes(x = date, y = -1, label = wd), color = "red", size = 2, family = "EB Garamond") +
        #geom_text(data = days[weekend == FALSE & date > "2020-04-02"], aes(x = date, y = -1, label = wd), color = "black", size = 2, family = "EB Garamond") +
        geom_point(aes(size = n_diff / 2, color = delay)) +
        geom_line(aes(y = perc90_days, linetype = "90th Percentile"), color = "#555555", alpha = 0.8) +
        scale_x_date(date_breaks = "1 month", date_labels = "%B", expand = c(0.02,0.02)) +
        scale_y_continuous(limits = c(-1, 32), expand = expansion(add = c(0, 0)), breaks = c(7, 14, 21, 28), minor_breaks = c(1, 2, 3, 5)) +
        scale_size(range = c(0.5, 5)) +
        scale_color_manual(values = colors) + #limits = label_order
        scale_linetype_manual(values = c("90th Percentile" = "dashed"), name = "Statistics") +
        default_theme +
        labs(size = "Number of deaths",
             color = "Reporting delay",
             x = "Report date",
             y = "Reporting delay (days)")
}

plot_lag_trends_grid <- function(lag_plot1, lag_plot2, default_theme) {
    loadd(default_theme)
    lag_plot1 <- plot_lag_trends1(readd(time_to_finished), readd(days), default_theme)
    lag_plot2 <- plot_lag_trends2(readd(death_dt), readd(days), default_theme)

    lag_plot1 <- lag_plot1 + theme(plot.margin = margin(0,-5,0,30))
    lag_plot2 <- lag_plot2 + theme(plot.margin = margin(0,30,0,-5))
    pgrid <- plot_grid(lag_plot1, lag_plot2,
                       rel_widths = c(1, 1.5),
                       align = "hv", axis = "bt")

    title_theme <- calc_element("plot.title", default_theme)
    title <- ggdraw() +
        draw_label("Swedish Covid-19 reporting delay",
                   fontface = title_theme$face, fontfamily = title_theme$family,
                   size = title_theme$size, lineheight = title_theme$lineheight,
                   x = 0, hjust = 0, y = 0) +
        theme(plot.margin = margin(30, 30, 0, 65))

    subtitle_theme <- calc_element("plot.subtitle", default_theme)
    subtitle <- ggdraw() +
        draw_label(paste0("Left: Length of delay per death date, measured as the number of days until date is completed.\n",
                          "Right: Shows how far back in time each daily report adds deaths. Point size is number of deaths added."),
                   fontface = subtitle_theme$face, fontfamily = subtitle_theme$family,
                   size = subtitle_theme$size, lineheight = subtitle_theme$lineheight,
                   x = 0, hjust = 0, y = 0) +
        theme(plot.margin = margin(0, 30, 15, 65))

    caption_theme <- calc_element("plot.caption", default_theme)
    caption <- ggdraw() +
        draw_label(
            paste0("Source: Folkhälsomyndigheten. Updated: ", Sys.Date(), ". Latest version available at https://adamaltmejd.se/covid."),
            fontface = caption_theme$face, fontfamily = caption_theme$family,
            size = caption_theme$size, lineheight = caption_theme$lineheight,
            color = caption_theme$colour,
            hjust = 1, x = 1
        ) +
        theme(plot.margin = margin(10, 134.5, 30, 30))

    pgrid_labels <- plot_grid(title, subtitle, pgrid, caption, ncol = 1, rel_heights = c(0.1, 0.105, 0.74, 0.09))

    return(pgrid_labels)
}

archive_plots <- function(out_dir) {
    files <- list.files("docs", pattern = ".png")
    files <- files[!grepl(Sys.Date(), files)]
    files <- files[!grepl("latest", files)]
    file.copy(file.path("docs", files), file.path(out_dir, files), overwrite = TRUE)
    unlink(file.path("docs", files))
}

save_plot <- function(p, f, bgcolor = "transparent") {
    require(ggplot2)
    require(tools)

    h <- 6 # inches
    w <- 11.46 # inches (twitter ratio 1.91:1)

    if (tools::file_ext(f) == "pdf") {
        cowplot::ggsave2(filename = f, plot = p,
           height = h, width = w,
           device = cairo_pdf)
    }
    if (tools::file_ext(f) == "png") {
        cowplot::ggsave2(filename = f, plot = p,
               height = h, width = w, dpi = 300,
               device = grDevices::png(), type = "cairo",
               bg = bgcolor, canvas = "#f5f5f5")
    }
}

update_web <- function(death_plot, lag_plot, index) {
    lines <- c(
        "---",
        "layout: page",
        "title: Reported Covid-19 deaths in Sweden",
        "author: Adam Altmejd",
        paste0("date: ", Sys.Date()),
        "---\n",
        paste0('![Graph of Swedish Covid-19 deaths with reporting delay.](', basename(death_plot), ' "Swedish Covid-19 deaths.")'),
        paste0('![Graph of Swedish Covid-19 reporting delay in daily deaths.](', basename(lag_plot), ' "Trend in Swedish Covid-19 mortality reporting delay.")'),
        "For code and data, visit <https://github.com/adamaltmejd/covid>.",
        "Evaluations of the statistical model and the old constant average forecast are available here: <https://github.com/adamaltmejd/covid/tree/master/docs/eval>.",
        "For an indepth explanation and evaluation of the nowcasting model, see <https://arxiv.org/abs/2006.06840>."
    )
    con <- file(index, "w")
    writeLines(lines, con = con)
    close(con)
}


