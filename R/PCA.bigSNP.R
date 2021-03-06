################################################################################

#' @name BigXYt
#' @description Compute linear kernel matrices for the genotype matrix of a "bigSNP"
#' with a particular scaling.
#' @title Linear kernel matrices for the genotype matrix of a "bigSNP".
#' @inheritParams bigsnpr-package
#' @param block.size Maximum number of loci read at once (for all individuals).
#' @param use.Eigen Use the \code{Eigen} library to compute \eqn{X X^T}, the default.
#' If \code{FALSE}, use \code{R}'s \code{tcrossprod}. See details.
#' @details To compute \eqn{X X^T}, using \code{Eigen} library is faster.
#' However, if you link \code{R} with an optimized math library,
#' using \code{R}'s \code{tcrossprod} can be faster.
#'
#' For example, you can easily link \code{R} with the
#' \href{https://software.intel.com/en-us/intel-mkl}{Intel®
#' Math Kernel Library} (Intel® MKL) through
#' \href{https://mran.revolutionanalytics.com/open/}{Microsoft
#' R Open} (MRO). It really improves performance
#' of \code{R} and \code{RcppArmadillo} matrix computations,
#' yet not the ones of \code{RcppEigen} (at least not directly).
#'
#' So, \enumerate{
#' \item \code{Eigen} should be prefered if you don't change anything,
#' \item base \code{R} should be prefered if you use MRO,
#' \item \code{Eigen} may be prefered if you manage to link \code{RcppEigen}
#' with the MKL (please \href{mailto:florian.prive.21@gmail.com}{contact me}
#' if you do!).}
#' @seealso \code{\link{bigSNP}} \code{\link{tcrossprod}}
#' @return Either \itemize{
#' \item A \code{big.matrix} of type \code{double} if all rows are used
#' in \code{ind.train}.
#' \item Two \code{big.matrix} of type \code{double}. One for
#' \eqn{X.train X.train^T} to get Principal Components
#' and one for \eqn{X.test X.train^T} to project the rest of the data.}
#' @export
#' @example examples/example.BigXYt.R
BigXYt <- function(x,
                   block.size,
                   ind.train = NULL,
                   use.Eigen = TRUE) {
  if (class(x) != "bigSNP") stop("x must be a bigSNP")

  X <- x$genotypes

  if (isNULL <- is.null(ind.train)) {
    ind.train <- seq(nrow(X))
    n <- length(ind.train)
  } else {
    n <- length(ind.train)
    n2 <- nrow(X) - n
    bigK2 <- bigmemory::big.matrix(n2, n, type = "double",
                                   init = 0, shared = F)
  }
  bigK <- bigmemory::big.matrix(n, n, type = "double",
                                init = 0, shared = F)


  # compute p
  p.all <- bigcolsumsChar(X@address, ind.train) / (2*n)

  # function to compute X*X^T
  printf("Computation of X * t(X)\n")
  intervals <- CutBySize(ncol(X), block.size)
  nb.block <- nrow(intervals)

  if (intr <- interactive()) {
    pb <- utils::txtProgressBar(min = 0, max = nb.block, style = 3)
  }

  for (j in 1:nb.block) {
    if (intr) utils::setTxtProgressBar(pb, j-1)
    ind <- seq2(intervals[j, ])
    p.ind <- p.all[ind]
    mean <- 2*p.ind
    sd <- sqrt(2*p.ind*(1-p.ind))

    tmp <- scaling(X[ind.train, ind], mean, sd)
    if (use.Eigen) {
      tcrossprodEigen(bigK@address, tmp)
    } else {
      incrSup(bigK@address, tcrossprod(tmp))
    }
    if (!isNULL) {
      if (use.Eigen) {
        tcrossprodEigen2(bigK2@address,
                         scaling(X[-ind.train, ind], mean, sd),
                         tmp)
      } else {
        incrAll(bigK2@address,
                tcrossprod(scaling(X[-ind.train, ind], mean, sd), tmp))
      }
    }
  }

  complete(bigK@address)

  if (intr) {
    utils::setTxtProgressBar(pb, nb.block)
    close(pb)
  }

  if (isNULL) {
    return(bigK)
  } else {
    return(list(bigK, bigK2))
  }
}

################################################################################

#' @name PCA.bigSNP
#' @title Principal Components of a "bigSNP".
#' @description Get k or all Principal Components (PCs) of a \code{bigSNP}
#' @inheritParams BigXYt
#' @param k Number of PCs to compute. Default is all.
#' @param thr.eigval Threshold to remove "unsignificant" PCs.
#' Default is \code{1e-3}.
#' @export
#' @return A \code{matrix} of PCs.
#' @details See \code{\link{BigXYt}}.
#'
#' Note that for the Eigen decomposition, only \code{R} is
#' used because is faster (see \href{http://goo.gl/UYJcCw}{stackoverflow}).
#' If you want a large number of eigenvectors/values, you should
#' really considerer using Microsoft R Open for speed.
#' @example examples/example.PCA.bigSNP.R
#' @seealso \code{\link{bigSNP}} \code{\link{prcomp}}
PCA.bigSNP <- function(x,
                       block.size,
                       k = NULL,
                       ind.train = NULL,
                       thr.eigval = 1e-3,
                       use.Eigen = TRUE) {
  if (class(x) != "bigSNP") stop("x must be a bigSNP")

  res <- BigXYt(x, block.size, ind.train, use.Eigen)
  n.all <- nrow(x$genotypes)
  if (isNULL <- is.null(ind.train)) {
    bigK <- res
    ind.train <- 1:n.all
  } else {
    bigK  <- res[[1]]
    bigK2 <- res[[2]]
  }
  rm(res)

  n <- nrow(bigK)
  means <- bigcolsumsDouble(bigK@address) / n
  symCenter(bigK@address, means, mean(means))
  if (!isNULL) colCenter(bigK2@address, means)

  if (is.null(k)) {
    eig <- eigen(bigK[,], symmetric = TRUE)
  } else {
    eig <- RSpectra::eigs_sym(bigK[,], k)
  }

  alphas <- scaling(eig$vectors,
                    rep(0, length(eig$values)),
                    sqrt(eig$values))
  m <- ncol(x$genotypes)
  lastEig <- max(which(eig$values > (thr.eigval * m)))
  rm(eig)
  alphas <- alphas[, 1:lastEig]

  rotated <- matrix(0, n.all, lastEig)
  rotated[ind.train, ] <- bigK[,] %*% alphas
  if (!isNULL) rotated[-ind.train, ] <- bigK2[,] %*% alphas

  return(rotated)
}

################################################################################

#' @name GBLUP
#' @title gBLUP of a "bigSNP".
#' @description Genetic Best Linear Unbiased Predictor (gBLUP)
#'  of a \code{bigSNP}
#' @inheritParams BigXYt
#' @param thr.eigval Threshold to remove eigenvalues to get
#' stability in the inversion of the matrix.
#' Default is \code{1e-3}.
#' @export
#' @return A \code{vector} of predictions.
#' @details See \code{\link{BigXYt}}.
#'
#' Note that for the Eigen decomposition, only \code{R} is
#' used because is faster (see \href{http://goo.gl/UYJcCw}{stackoverflow}).
#' If you want a large number of eigenvectors/values, you should
#' really considerer using Microsoft R Open for speed.
#' @example examples/example.GBLUP.R
#' @seealso \code{\link{bigSNP}}
GBLUP <- function(x, block.size, ind.train,
                  thr.eigval = 1e-3,
                  use.Eigen = TRUE) {
  if (class(x) != "bigSNP") stop("x must be a bigSNP")

  res <- BigXYt(x, block.size, ind.train, use.Eigen)

  bigK  <- res[[1]]
  bigK2 <- res[[2]]
  rm(res)

  n <- nrow(bigK)
  means <- bigcolsumsDouble(bigK@address) / n
  symCenter(bigK@address, means, mean(means))
  colCenter(bigK2@address, means)

  eig <- eigen(bigK[,], symmetric = TRUE)

  m <- ncol(x$genotypes)
  lastEig <- max(which(eig$values > (thr.eigval * m)))

  y.train <- x$fam$affection[ind.train]
  ind <- 1:lastEig
  tmp <- crossprod(eig$vectors[, ind], y.train - mean(y.train))
  tmp2 <- tmp / eig$values[ind]
  tmp3 <- eig$vectors[, ind] %*% tmp2
  pred <- bigK2[,] %*% tmp3 + mean(y.train)

  return(pred)
}

################################################################################
