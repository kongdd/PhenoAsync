# library(plsdepot) # install_github('kongdd/plsdepot')

## Global variables
varnames <- c("EVI", "NDVI", "T", "Prcp", "Rs", "VPD", "GPP", paste0("GPP_t", 1:3))[1:7]
# formula  <- varnames %>% paste(collapse = "+") %>% {as.formula(paste("GPP~", .))}

# ============================ GPP_vpm theory ==================================
# In the order of IGBPname_006
# https://github.com/zhangyaonju/Global_GPP_VPM_NCEP_C3C4/blob/master/GPP_C6_for_cattle.py
epsilon_C3 <- 0.078 # g C m-2 day -1 /W m-2
epsilon_C4 <- c(rep(0, 8), rep(epsilon_C3*1.5, 4), 0, epsilon_C3*1.5)

# param <- data.table(IGBPname, Tmin, Tmax, Topt)
# Tscalar <- (T-Tmax)*(T-Tmin) / ( (T-Tmax)*(T-Tmin) - (T - Topt)^2 )
# Wscaler <- (1 + LSWI) / (1 + LSWI_max)
# ==============================================================================

getRange <- function(d, variable, by = .(IGBP)){
    if (is.quoted(by)) by <- names(by)
    eval(parse(text = sprintf('d[, .(min = min(%s, na.rm = T), max = max(%s, na.rm = T)), by]',
                              variable, variable)))
}

# only for site data
scaleVar_byGPP <- function(d, variable = "EVI"){
    range_org <- getRange(d, variable)[,.(min, max)] %>% as.numeric()
    range_new <- getRange(d, "GPP")[,.(min, max)] %>% as.numeric()

    coef <- lm(range_new~range_org) %>% coef()
    eval(parse(text = sprintf("d[, %s_z := %s*%f+%f]", variable, variable, coef[2], coef[1])))
    d
}
#' scaleGPP_ByCoef
#' scaled GPP into same range of coef, by IGBP
#'
#' @param d A data.frame with the columns of 'min' and 'max' and 'GPP'
scaleGPP_ByCoef <- function(d){
    d <- data.table(d) # The stupid ddply

    range_new  <- d[1, .(min, max)] %>% as.numeric()
    range_org  <- d[, .(min = min(GPP), max = max(GPP))] %>% as.numeric()

    coef <- lm(range_new~range_org) %>% coef()
    d[, GPP_z := (GPP*coef[2]+coef[1])]
    d[, .(min = min(GPP), max = max(GPP))]
    d
}

lm_coef <- function(x) {
    l <- lm(formula, x)
    # glance(l_lm)
    coefs0 <- tidy(l) %$% set_names(estimate, term)
    coefs0 <- coefs0[-1] # omit intercept

    ## reorder coef
    coefs <- rep(NA, length(varnames)) %>% set_names(varnames)
    coefs[match(names(coefs), varnames)] <- coefs0
    c(coefs, n = nrow(x))
}

#' reorder variables
match_varnames <- function(coefs0, varnames){
    ## reorder coef
    coefs <- rep(NA, length(varnames)) %>% set_names(varnames)
    coefs[match(names(coefs0), varnames)] <- coefs0
    coefs
}

pls_coef <- function(x, predictors_var = varnames, response_var = "GPP_DT"){
    if (is.data.table(x)){
        predictors <- x[, .SD, .SDcols = predictors_var]
    } else {
        predictors <- x[, predictors_var]
    }
    predictors %<>% as.matrix()

    # rm ALL is.na variable
    I_col      <- apply(predictors, 2, function(x) !all(is.na(x))) %>% which()
    predictors <- predictors[, I_col]

    response  <- x[[response_var]] %>% as.matrix(ncol = 1)
    # ERROR when comps = 1, 20180926
    l_pls     <- plsreg1(predictors, response, comps = 2, crosval = TRUE)
    coefs     <-  l_pls$std.coefs %>% match_varnames(predictors_var)

    # c(coefs, n = nrow(x))
    VIP <- l_pls$VIP %>% .[nrow(.), ] %>% match_varnames(predictors_var)
    n = nrow(x)
    c(coef = coefs, VIP = VIP, n = n)
    # list(coef = c(coefs, n = n),
    #     VIP = c(VIP, n = n))
}

#' autocorrelation coefficientn
get_acf <- function(x){
    acf(x, lag.max = 10, plot = F, na.action = na.pass)$acf[,,1][-1]
}

## 2. Test the difference of `pls` and 'lm'
test <- function(){
    par(mfrow = c(2, 1))
    # yhat <- predict(pls1_one, predictors)
    plot(response[[1]], l_pls$y.pred);abline(a = 0, b = 1, col = "red"); grid()

    yhat_lm <- predict(l_lm, x)
    plot(response[[1]], yhat_lm);abline(a = 0, b = 1, col = "red"); grid()


    fit <- data.table(yobs = response[[1]],
                      y_pls = l_pls$y.pred,
                      y_lm = yhat_lm)

    with(na.omit(fit),
         list(pls = GOF(yobs, y_pls) %>% as.data.frame.list(),
              lm  = GOF(yobs, y_lm ) %>% as.data.frame.list()) %>% melt_list("meth"))
    with(fit,
         list(pls = GOF(yobs, y_pls) %>% as.data.frame.list(),
              lm  = GOF(yobs, y_lm ) %>% as.data.frame.list()) %>% melt_list("meth"))
}


## visualization



GPP_D1 <- function(x, predictors){
    varnames <- c(predictors, "GPP")
    ## 1. dx cal should be by site
    x <- data.table(x)
    headvars <- c("site", "date", "year", "ydn", "dn")

    I_t0 <- x$ydn
    I_t1 <- match(I_t0 - 1, I_t0) # previous time step

    # back forward derivate
    x_t1 <- x[I_t1]
    dx   <- x[, ..varnames] - x_t1[, ..varnames] # first order derivate

    # dx divide x_bar, absolute change become relative change
    mean_dx <- dx[, ..varnames] %>% colMeans(na.rm = T)
    mean_x  <- x[, ..varnames] %>% colMeans(na.rm = T)

    # standardized by mean. `_z` means standardized
    mean_x_inv <- rep(1/mean_x, nrow(dx)) %>% matrix(byrow = T, nrow = nrow(dx))

    dx_z <- dx[, ..varnames] * mean_x_inv
    dx_z <- cbind(x[, ..headvars], dx_z)

    dx_z
}

########################### ELASTICITY FUNCTIONS ###############################
figureNo <- 0

# global variables:
# st, info_async
#' check_sensitivity
#' @export 
check_sensitivity <- function(x, predictors){
    ## 0. prepare plot data
    dx_z <- GPP_D1(x, predictors) # only suit for by site
    p <- ggplot(x, aes(dn, GPP, color = year)) +
        # geom_point() +
        geom_smooth(method = "loess",
            # formula = smooth_formula, span = span,
            color = "black")

    p_EVI  <- ggplot_1var(x, "EVI" , "green")
    p_APAR <- ggplot_1var(x, "APAR", "red")
    p_Rs   <- ggplot_1var(x, "Rs"  , "purple")
    p_T    <- ggplot_1var(x, "TS"   , "yellow")
    p_VPD  <- ggplot_1var(x, "VPD" , "darkorange1")
    p_prcp <- ggplot_1var(x, "Prcp", "skyblue")
    p_epsilon_eco <- ggplot_1var(x, "epsilon_eco", "darkorange1")
    p_epsilon_chl <- ggplot_1var(x, "epsilon_chl", "yellow")

    p_Wscalar <- ggplot_1var(x, "Wscalar", "blue")
    p_Tscalar <- ggplot_1var(x, "Tscalar", "yellow4")
    # browser()
    # p_all <- ggplot_multiAxis(p, p_apar)
    p1 <- reduce(list(p, p_EVI, p_APAR, p_Rs, p_epsilon_eco, p_epsilon_chl), ggplot_multiAxis, show = F)
    p2 <- reduce(list(p, p_EVI, p_T, p_VPD, p_prcp, p_Wscalar, p_Tscalar), ggplot_multiAxis, show = F)

    fontsize <- 14
    titlestr <- st[site == sitename, ] %$%
        sprintf("[%s] %s, lat=%.2f, nyear=%.1f", IGBP, site, lat, nrow(x)/23)
    # biasstr  <- with(info_async[site == sitename], sprintf("bias: sos=%.1f,eos=%.1f", spring, autumn))
    # titlestr <- paste(titlestr, biasstr, sep = "  ")

    title <- textGrob(titlestr, gp=gpar(fontsize=fontsize, fontface = "bold"))

    p_series <- arrangeGrob(p1, p2, ncol = 1, top = title)
    # grid.newpage();grid.draw(p_series)
    # ggplot_build(p)$layout$panel_scales_y[[1]]$range$range

    ## 2. mete forcing
    delta <- dx_z %>% melt(c("site", "date", "year", "ydn", "dn", "GPP"))

    formula <- y ~ x
    p_mete <- ggplot(delta[dn > 10], aes(value, GPP)) +
        geom_point() +
        facet_wrap(~variable, scales = "free", ncol = 2) +
        geom_smooth(method = "lm", se=T, formula = formula) +
        stat_poly_eq(formula = formula,
                    eq.with.lhs = "italic(hat(y))~`=`~",
                    rr.digits = 2,
                    aes(label = paste(..eq.label.., ..rr.label.., sep = "~"), color = "red"),
                    parse = TRUE) +
        ggtitle("dGPP ~ dx")
    # print(p_mete)

    # avoid empty figure in first page
    if (!(exists("figureNo") & figureNo == 0)){
        grid.newpage()
    }
    if (exists("figureNo")) figureNo <<- figureNo + 1
    arrangeGrob(p_series, p_mete) %>% grid.draw()
}

# plot(pls1_one, "observations")
# l <- lm(GPP ~ Rn + VPD + Prcp + T + EVI, x) #%>% plot()

#' @rdname check_sensitivity
#' @examples
#' # predictors <- c("EVI", "Rs", "TA", "Prcp", "VPD", "APAR")#[-6]#[-c(1, 2)]
#' # check_sensitivity(x, predictors)
check_sensitivity_async <- function(x, predictors){
    ## 0. prepare plot data
    dx_z <- GPP_D1(x, predictors) # only suit for by site

    p <- ggplot(x, aes(dn, GPP, color = year)) +
        # geom_point() +
        geom_smooth(method = "loess",
            # formula = smooth_formula, span = span,
            color = "black")

    p_GPPsim  <- ggplot_1var(x, "GPP_sim" , "grey60")
    p_EVI  <- ggplot_1var(x, "EVI" , "green")
    p_APAR <- ggplot_1var(x, "APAR", "red")
    p_Rs   <- ggplot_1var(x, "Rs"  , "purple")
    p_T    <- ggplot_1var(x, "TS"   , "yellow")
    p_VPD  <- ggplot_1var(x, "VPD" , "darkorange1")
    p_prcp <- ggplot_1var(x, "Prcp", "skyblue")
    p_epsilon_eco <- ggplot_1var(x, "epsilon_eco", "darkorange1")
    p_epsilon_chl <- ggplot_1var(x, "epsilon_chl", "yellow")

    p_Wscalar <- ggplot_1var(x, "Wscalar", "blue")
    p_Tscalar <- ggplot_1var(x, "Tscalar", "yellow4")
    # browser()
    # p_all <- ggplot_multiAxis(p, p_apar)
    # p_epsilon_eco, p_epsilon_chl
    p1 <- reduce(list(p, p_EVI, p_APAR, p_Rs, p_VPD), ggplot_multiAxis, show = F)
    p2 <- reduce(list(p, p_EVI, p_T, p_prcp, p_Wscalar, p_Tscalar), ggplot_multiAxis, show = F)

    fontsize <- 14
    titlestr <- st[site == sitename, ] %$%
        sprintf("[%s] %s, lat=%.2f, nyear=%.1f", IGBP, site, lat, nrow(x)/23)
    # biasstr  <- with(info_async[site == sitename], sprintf("bias: sos=%.1f,eos=%.1f", spring, autumn))
    # titlestr <- paste(titlestr, biasstr, sep = "  ")

    title <- textGrob(titlestr, gp=gpar(fontsize=fontsize, fontface = "bold"))

    p_series <- arrangeGrob(p1, p2, ncol = 1, top = title)
    # grid.newpage();grid.draw(p_series)
    # ggplot_build(p)$layout$panel_scales_y[[1]]$range$range

    ## 2. mete forcing
    delta <- dx_z %>% melt(c("site", "date", "year", "ydn", "dn", "GPP"))

    formula <- y ~ x
    p_mete <- ggplot(delta[dn > 10], aes(value, GPP)) +
        geom_point() +
        facet_wrap(~variable, scales = "free", ncol = 2) +
        geom_smooth(method = "lm", se=T, formula = formula) +
        stat_poly_eq(formula = formula,
                    eq.with.lhs = "italic(hat(y))~`=`~",
                    rr.digits = 2,
                    aes(label = paste(..eq.label.., ..rr.label.., sep = "~"), color = "red"),
                    parse = TRUE) +
        ggtitle("dGPP ~ dx")
    # print(p_mete)

    # avoid empty figure in first page
    if (!(exists("figureNo") & figureNo == 0)){
        grid.newpage()
    }
    if (exists("figureNo")) figureNo <<- figureNo + 1
    arrangeGrob(p_series, p_mete) %>% grid.draw()
}
