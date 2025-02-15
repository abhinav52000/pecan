##' @title EnKF.MultiSite
##' @name  EnKF.MultiSite
##' @author Michael Dietze \email{dietze@@bu.edu}, Ann Raiho and Hamze Dokoohaki
##' 
##' @param settings  pecan standard settings list.  
##' @param Forecast A list containing the forecasts variables including Q (process variance) and X (a dataframe of forecasts state variables for different ensemble)
##' @param Observed A list containing the observed variables including R (cov of observed state variables) and Y (vector of estimated mean of observed state variables)
##' @param H is a mtrix of 1's and 0's specifying which observations go with which state variables.
##' @param extraArg This argument is NOT used inside this function but it is a list containing aqq, bqq and t. The aqq and bqq are shape parameters estimated over time for the proccess covariance and t gives the time in terms of index of obs.list.
##' @param ... Extra argument sent to the analysis function.
##' @details This function is different than `EnKF` function in terms of how it creates the Pf matrix.
##'  
##' 
##' @description Given the Forecast and Observed this function performs the Ensemble Kalamn Filter. 
##' 
##' @return It returns a list with estimated mean and cov matrix of forecast state variables as well as mean and cov estimated as a result of assimilation/analysis .
##' @export
EnKF.MultiSite <-function(setting, Forecast, Observed, H, extraArg=NULL, ...){
  #------------------------------Setup
  Localization.FUN <- settings$state.data.assimilation$Localization.FUN # localization function
  scalef <- settings$state.data.assimilation$scalef %>% as.numeric() # scale factor for localization
  var.names <- sapply(settings$state.data.assimilation$state.variable, '[[', "variable.name")
  #-- reading the dots and exposing them to the inside of the function
  dots<-list(...)
  if (length(dots)>0) lapply(names(dots),function(name){assign(name,dots[[name]])})
  for(i in seq_along(dots)) assign(names(dots)[i],dots[[names(dots)[i]]])

    #Forcast inputs 
  Q <- Forecast$Q # process error
  X <- Forecast$X # states 
  #Observed inputs
  R <- Observed$R
  Y <- Observed$Y

  # Enkf---------------------------------------------------
  mu.f <- as.numeric(apply(X, 2, mean, na.rm = TRUE)) %>%
    `attr<-`('Site', c(rep(site.ids, each=length(var.names))))
  # I make the Pf in a separate function
  if(length(site.ids)>1){
    # This the function makes the Pf by creating blocks in a matrix for different sites
    # We can also send a localization functions to this 
    # for extra argumnets like distance matrix for localization use elipsis
    Pf <- Contruct.Pf (site.ids, var.names, X,
                       localization.FUN=eval(parse(text = Localization.FUN)),
                       t=extraArg$t,
                       blocked.dis,
                       scalef)
  }else{
    PEcAn.logger::logger.severe("You need to send this function a multisetting object containing multiple sites/runs.")
  }
  ## process error
  if (!is.null(Q)) {
    Pf <- Pf + Q
  }
  
  
  if (length(Y) > 1) {
    PEcAn.logger::logger.info("The zero variances in R and Pf is being replaced by half and one fifth of the minimum variance in those matrices respectively.")
    diag(R)[which(diag(R)==0)] <- min(diag(R)[which(diag(R) != 0)])/2
    diag(Pf)[which(diag(Pf)==0)] <- min(diag(Pf)[which(diag(Pf) != 0)])/5
  }
  
  ## Kalman Gain
  K <- Pf %*% t(H) %*% solve((R + H %*% Pf %*% t(H)))
  # Analysis
  mu.a <- mu.f + K %*% (Y - H %*% mu.f)
  Pa   <- (diag(ncol(X)) - K %*% H) %*% Pf
  return(list(mu.f = mu.f, Pf = Pf, mu.a = mu.a, Pa = Pa))
}



##' @rdname GEF
##' @export
GEF.MultiSite<-function(setting, Forecast, Observed, H, extraArg,...){
  #------------------------------Setup
  #-- reading the dots and exposing them to the inside of the function
  dots<-list(...)
  if (length(dots) > 0) lapply(names(dots),function(name){assign(name,dots[[name]], pos = 1 )})
  #General
  var.names <- sapply(settings$state.data.assimilation$state.variable, '[[', "variable.name")
  # What type of Q needs to be estimated ? if it's defined then it's either Site or PFT based if not then it's one for all.
  q.type <- toupper(settings$state.data.assimilation$q.type)
  
  single.q <-1
  Site.q <-2
  pft.q <-3
  
  if (is.null(q.type) | q.type=="SINGLE") {
    q.type <- single.q
  } else{
    q.type <- ifelse(q.type == "SITE", Site.q, pft.q)
  } 
  #Forecast inputs 
  Q <- Forecast$Q # process error
  X <- Forecast$X # states 
  Pf = cov(X) # Cov Forecast - This is used as an initial condition
  diag(Pf)[which(diag(Pf)==0)] <- min(diag(Pf)[which(diag(Pf) != 0)])/5 #fixing det(Pf)==0
  
  mu.f <- colMeans(X) #mean Forecast - This is used as an initial condition
  #Observed inputs
  R <- Observed$R
  Y <- Observed$Y
  wish.df <- function(Om, X, i, j, col) {
    (Om[i, j]^2 + Om[i, i] * Om[j, j]) / stats::var(X[, col])
  }
  #----------------------------------- GEF-----------------------------------------------------
  # Taking care of censored data ------------------------------    
  ### create matrix the describes the support for each observed state variable at time t
  interval <- NULL
  X.new <- NULL
  # Reading the extra arguments
  aqq <- extraArg$aqq
  bqq <- extraArg$bqq
  wts <- extraArg$wts/sum(extraArg$wts)
  if(any(is.na(wts))){
    PEcAn.logger::logger.warn(
      "We found an NA in the wts for the ensemble members.",
      "Is this what you want? For now, we will change the NA to a zero.")
    wts[is.na(wts)] <- 0
  }
  if(sum(wts==0)){
    wts <- rep(1,nrow(X))/nrow(X)
  }
  t <- extraArg$t
  nitr.GEF<-extraArg$nitr.GEF
  nthin<-extraArg$nthin
  nburnin <- extraArg$nburnin
  censored.data <- extraArg$censored.data
  ###-------------------------------------------------------------------###
  # if we had censored data
  ###-------------------------------------------------------------------###----
  if (censored.data) {
    intervalX <- matrix(NA, ncol(X), 2)
    rownames(intervalX) <- colnames(X)
    outdir     <- settings$modeloutdir
    #TO DO: Not working for fcomp
    for (i in 1:length(var.names)) {
      intervalX[which(startsWith(rownames(intervalX),
                                 var.names[i])),] <-
        matrix(c(
          as.numeric(
            settings$state.data.assimilation$state.variables[[i]]$min_value
          ),
          as.numeric(
            settings$state.data.assimilation$state.variables[[i]]$max_value
          )
        ),
        length(which(startsWith(
          rownames(intervalX),
          var.names[i]
        ))), 2, byrow = TRUE)
      
    }
    #### These vectors are used to categorize data based on censoring from the interval matrix
    x.ind <- x.censored <- matrix(NA, ncol = ncol(X), nrow = nrow(X))
    for (j in seq_along(mu.f)) {
      for (n in seq_len(nrow(X))) {
        x.ind[n, j] <- as.numeric(X[n, j] > 0)
        x.censored[n, j] <-
          as.numeric(ifelse(X[n, j] > intervalX[j, 2], 0, X[n, j])) #
      }
    }
    
    if (t == 1) {
      #The purpose of this step is to impute data for mu.f
      #where there are zero values so that
      #mu.f is in 'tobit space' in the full model
      diag(Pf)[which(diag(Pf)<0.1)] <- min(diag(Pf)[which(diag(Pf) >= 0.1)]) #fixing det(Pf)==0
      constants.tobit2space = list(N = nrow(X),
                                   J = length(mu.f))
      data.tobit2space <- list(y.ind = x.ind,
                               y.censored = x.censored,
                               mu_0 = rep(0,length(mu.f)),
                               lambda_0 = solve(diag(1000,length(mu.f))), #can try solve
                               nu_0 = ncol(X)+1,
                               wts = wts*nrow(X), #sigma x2 max Y
                               Sigma_0 = solve(diag(1000,length(mu.f))))#some measure of prior obs
      
      inits.tobit2space <<-
        list(pf = Pf, muf = colMeans(X)) #pf = cov(X)
      #set.seed(0)
      #ptm <- proc.time()
      tobit2space_pred <<-
        nimbleModel(
          tobit2space.model,
          data = data.tobit2space,
          constants = constants.tobit2space,
          inits = inits.tobit2space,
          name = 'space'
        )
      ## Adding X.mod,q,r as data for building model.
      conf_tobit2space <<-
        configureMCMC(tobit2space_pred, thin = 10, print = TRUE)
      conf_tobit2space$addMonitors(c("pf", "muf", "y.censored"))
      ## important!
      ## this is needed for correct indexing later
      samplerNumberOffset_tobit2space <<-
        length(conf_tobit2space$getSamplers())
      
      for (j in seq_along(mu.f)) {
        for (n in seq_len(nrow(X))) {
          node <- paste0('y.censored[', n, ',', j, ']')
          conf_tobit2space$addSampler(node, 'toggle', control = list(type =
                                                                       'RW'))
        }
      }
      
      #conf_tobit2space$printSamplers()
      
      Rmcmc_tobit2space <<- buildMCMC(conf_tobit2space)
      
      Cmodel_tobit2space <<- compileNimble(tobit2space_pred)
      Cmcmc_tobit2space <<-
        compileNimble(Rmcmc_tobit2space, project = tobit2space_pred)
      
      for (i in seq_along(X)) {
        ## ironically, here we have to "toggle" the value of y.ind[i]
        ## this specifies that when y.ind[i] = 1,
        ## indicator variable is set to 0, which specifies *not* to sample
        valueInCompiledNimbleFunction(Cmcmc_tobit2space$samplerFunctions[[samplerNumberOffset_tobit2space +i]],
                                      'toggle',1 - x.ind[i])
      }
      
    } else{
      Cmodel_tobit2space$y.ind <- x.ind
      Cmodel_tobit2space$y.censored <- x.censored
      
      inits.tobit2space = list(pf = Pf, muf = colMeans(X))
      Cmodel_tobit2space$setInits(inits.tobit2space)
      
      for (i in seq_along(X)) {
        valueInCompiledNimbleFunction(Cmcmc_tobit2space$samplerFunctions[[samplerNumberOffset_tobit2space +i]],
                                      'toggle',1 - x.ind[i])
      }
      
    }
    
    dat.tobit2space <-
      runMCMC(Cmcmc_tobit2space,
              nchains = 1,
              niter = 50000,
              progressBar = TRUE)
    #dat.tobit2space <- do.call(rbind, dat.tobit2space)
    save(dat.tobit2space, file = file.path(settings$outdir, paste0('censored',t,'.Rdata')))
    ## update parameters
    mu.f <-
      colMeans(dat.tobit2space[, grep("muf", colnames(dat.tobit2space))])
    Pf <-
      matrix(colMeans(dat.tobit2space[, grep("pf", colnames(dat.tobit2space))]), ncol(X), ncol(X))


    
    iycens <- grep("y.censored", colnames(dat.tobit2space))
    X.new <-
      matrix(colMeans(dat.tobit2space[, iycens]), nrow(X), ncol(X))
  } # end of if we have censored data
  
  
  ###-------------------------------------------------------------------###
  # Generalized Ensemble Filter                                       ###-----
  ###-------------------------------------------------------------------###
  # if(sum(diag(Pf)-diag(cov(X))) > 10 | sum(diag(Pf)-diag(cov(X))) < -10) logger.severe('Increase Sample Size')
  #--- This is where the localization needs to happen - After imputing Pf
  elements.W.Data <- which(apply(H, 2, sum) == 1)
  if (exists('blocked.dis')){
        Pf <-
      Local.support(Pf,
                    blocked.dis,
                    settings$state.data.assimilation$scalef %>% as.numeric())
  }

  #### initial conditions
  ## We are figuring out the aqq here 
  if (t == 1) {
    bqq[1] <- length(elements.W.Data)
    
    if (is.null(aqq)) {
      
      if (q.type==Site.q) { # if we wanna estimate a q per site
        aqq <-
          array(1, dim = c(length(elements.W.Data), length(elements.W.Data), nt))
        for (i in 1:nt) {
          aqq[,,i] <- diag(length(elements.W.Data))
        }
      } else if(q.type == pft.q){ # if we wanna estimate a q per PFT
        
        site.pfts <- settings %>%
          map( ~ .x[['run']]) %>%
          map('site') %>%
          map('site.pft') %>%
          map('pft.name') %>%
          modify(as.factor) %>%
          modify(as.numeric) %>%
          modify_if(function(x) {
            if (length(x) > 0) {
              return(FALSE)
            } else{
              return(TRUE)
            }
          },  ~ 1) %>%
          unlist()
        
        aqq<- array(1, dim = c(max(site.pfts), max(site.pfts), nt))
      }else{ # This is where we estimate just one q for all
        aqq<- array(1, dim = c(1, 1, nt))
      }

    } else{
      if (length(elements.W.Data) != dim(aqq)[1] |
          length(elements.W.Data) != dim(aqq)[2]) {
        PEcAn.logger::logger.warn('error: X has changed dimensions')
      }
    }

  } else{
    # if(length(elements.W.Data)==ncol(aqq[, , t])){
      if (ncol(aqq) > 1 & nrow(aqq) > 1)
        aqq[, , t] <- Local.support(
          aqq[, , t],
          distances[ceiling(elements.W.Data/length(var.names)), # finding sites with data
                    ceiling(elements.W.Data/length(var.names))],
          settings$state.data.assimilation$scalef %>% as.numeric()
        )
    # }
    
  }


  
  ### create matrix the describes the support for each observed state variable at time t
  interval <- matrix(NA, length(unlist(obs.mean[[t]])), 2)
  
  # if this function is revoked by multisite then the structure of data looks a bit different.
  if (exists('blocked.dis')){
    rownames(interval) <- obs.mean[[t]] %>% purrr::flatten() %>% names()
    
  }else{
    rownames(interval) <- names(obs.mean[[t]])
  }
  
  for (i in 1:length(var.names)) {
    interval[which(startsWith(rownames(interval),
                              var.names[i])),] <-
      matrix(c(
        as.numeric(
          settings$state.data.assimilation$state.variables[[i]]$min_value
        ),
        as.numeric(
          settings$state.data.assimilation$state.variables[[i]]$max_value
        )
      ),
      length(which(startsWith(
        rownames(interval),
        var.names[i]
      ))), 2, byrow = TRUE)
  }
  #### These vectors are used to categorize data based on censoring
  #### from the interval matrix
  y.ind <- as.numeric(Y > interval[, 1])
  y.censored <- as.numeric(ifelse(Y > interval[, 1], Y, 0))
  
  recompileGEF <- extraArg$recompileGEF
  if(t == 1 | recompileGEF){ #TO DO need to make something that works to pick whether to compile or not
  # initial Q depends on the size of aqq
    aq.arg <- aqq[,,t]
    
    #Initial values
    inits.pred <-
      list(
        X.mod = as.vector(mu.f),
        X = as.vector(mu.f)[elements.W.Data],
        Xall = as.vector(mu.f),
        Xs = as.vector(mu.f)[elements.W.Data],
        q = diag(1, length(elements.W.Data), length(elements.W.Data))
      ) #
    dimensions.tobit = list(X = length(elements.W.Data),
                            X.mod = ncol(X),
                            Q = c(nrow(aqq), ncol(aqq))
    )
    
    # Contants defined in the model
    constants.tobit <-
      list(
        N = ncol(X),
        YN = length(elements.W.Data),
        nH = length(elements.W.Data),
        H = elements.W.Data,
        NotH = which(!(1:ncol(X) %in% elements.W.Data )),
        nNotH = which(!(1:ncol(X) %in% elements.W.Data )) %>% length(),
        q.type=q.type
      )
    # Data used for setting the likelihood and other stuff
    data.tobit <-
      list(
        muf = as.vector(mu.f),
        pf = Pf,
        aq = aq.arg,
        bq = bqq[t],
        y.ind = y.ind,
        y.censored = y.censored,
        r = solve(R)
      )

  # This is the first step in making the nimble model - Nimble does some preliminary checks on the code 
    #special case for YN == 1 to run nimble model without for loops around nH
    if(constants.tobit$YN == 1){
      #add error message if trying to run SDA with 1 obs and 1 state variable no model currently exists to handle this case, need to remove for loop from GEF_singleobs_nimble for this case and save new model
      if(constants.tobit$N == 1){
        PEcAn.logger::logger.error("No model exists for assimilating 1 observation and 1 state variable, add more state variables or edit GEF_singleobs_nimble to work with 1 state variable")
      }
      #slight adjustment to inputs for nimble function when running with 1 obs
      inits.pred$qq <- 0.368
      dimensions.tobit$y.censored <- 1
      dimensions.tobit$y.ind <- 1
      constants.tobit$q.type <- NULL
      
      model_pred <- nimbleModel(GEF_singleobs_nimble,
                                data = data.tobit,
                                dimensions = dimensions.tobit,
                                constants = constants.tobit,
                                inits = inits.pred,
                                name = 'base')
    }else{
      model_pred <- nimbleModel(GEF.MultiSite.Nimble,
                                data = data.tobit,
                                dimensions = dimensions.tobit,
                                constants = constants.tobit,
                                inits = inits.pred,
                                name = 'base')
    }
    
    
    
    
    model_pred$initializeInfo()
    ## Adding X.mod,q,r as data for building model.
    conf <- configureMCMC(model_pred, print=TRUE)
    
    conf$addMonitors(c("X","Xall","q","Xs")) 
    samplerNumberOffset <<- length(conf$getSamplers())
    
      for(i in 1:length(y.ind)) {
        node <- paste0('y.censored[',i,']')
        conf$addSampler(node, 'toggle', control=list(type='RW'))
      }


    conf$printSamplers()

    Rmcmc <<- buildMCMC(conf)
    Cmodel <<- compileNimble(model_pred)
    Cmcmc <<- compileNimble(Rmcmc, project = model_pred, showCompilerOutput = TRUE)
    
    for(i in 1:length(y.ind)) {
        valueInCompiledNimbleFunction(Cmcmc$samplerFunctions[[samplerNumberOffset+i]], 'toggle', 1-y.ind[i])
      }

    
    
    save(
      inits.pred,
      dimensions.tobit,
      constants.tobit,
      data.tobit,
      model_pred,
      conf,
      Rmcmc,
      Cmodel,
      Cmcmc,
      file = file.path(settings$outdir,"NimbleVars.RData")
    )
    # if t>1 in GEF --------------------------------------------   
  } else {

    Cmodel$y.ind <- y.ind
    Cmodel$y.censored <- y.censored
    Cmodel$aq <- aqq[ , ,t]
    Cmodel$bq <- bqq[t]
    Cmodel$muf <- mu.f
    Cmodel$pf <- Pf
    Cmodel$r <- solve(R)
    
    # inits.pred = list(q = diag(length(elements.W.Data)),
    #                   X.mod = as.vector(mu.f),
    #                   X = as.vector(mu.f)[elements.W.Data]) #
    inits.pred <-
      list(
        X.mod = as.vector(mu.f),
        X = as.vector(mu.f)[elements.W.Data],
        Xall = as.vector(mu.f),
        Xs = as.vector(mu.f)[elements.W.Data],
        q = diag(1, length(elements.W.Data), length(elements.W.Data))
      ) #
    Cmodel$setInits(inits.pred)
    
    for(i in 1:length(y.ind)) {
      ## ironically, here we have to "toggle" the value of y.ind[i]
      ## this specifies that when y.ind[i] = 1,
      ## indicator variable is set to 0, which specifies *not* to sample
      valueInCompiledNimbleFunction(Cmcmc$samplerFunctions[[samplerNumberOffset+i]], 'toggle', 1-y.ind[i])
    }
    
  }


  dat <- runMCMC(Cmcmc, niter = nitr.GEF, nburnin = nburnin, thin = nthin, nchains = 1)
  #browser()
  #dat <- do.call(rbind, dat)
  
  #---- Saving the chains
  save(dat, file=file.path(settings$outdir, paste0('dat',t,'.Rdata')))
  
  ## update parameters
  iX   <- grep("Xall[", colnames(dat), fixed = TRUE)
  mu.a <- colMeans(dat[, iX])
  Pa   <- cov(dat[, iX])
  Pa[is.na(Pa)] <- 0
  mq <- dat[,  grep("q", colnames(dat))]  # Omega, Precision
  q.bar <- matrix(apply(mq, 2, mean),
                  length(elements.W.Data),
                  length(elements.W.Data)
                  )  # Mean Omega, Precision

  # Setting up the prior for the next step from the posterior of this step
  if (t < nt){
    if (q.type == single.q){ #if it's a gamma case
      
      aqq[1, 1, t + 1] <- mean(mq)
      bqq[t + 1] <- stats::var(mq  %>%  as.numeric())
      
    } else { # if it's a wish case
      col <- matrix(1:length(elements.W.Data) ^ 2,
                    length(elements.W.Data),
                    length(elements.W.Data))
      
      WV  <- matrix(0, length(elements.W.Data), length(elements.W.Data))
      
      for (i in seq_along(elements.W.Data)) {
        for (j in seq_along(elements.W.Data)) {
          WV[i, j] <- wish.df(q.bar, X = mq, i = i, j = j, col = col[i, j])
        }
      }
      
      n <- mean(WV)
      if (n < length(mu.f)) {
        n <- length(mu.f)
      }
      V <- solve(q.bar) * n
      
      
      aqq[, ,t + 1] <- V
      bqq[t + 1] <- n
    }

  }
  

  

  #---- Trying to release some of the memory back to the os 
  gc()
  #
  return(list(mu.f = mu.f,
              Pf = Pf,
              mu.a = mu.a,
              Pa = Pa,
              q.bar = q.bar,
              n = n,
              X.new=X.new,
              aqq=aqq,
              bqq=bqq
  )
  )
}


