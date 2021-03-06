#' Extract coverage information for a set of regions
#'
#' This function extracts the raw coverage information calculated by 
#' \link{fullCoverage} at each base for a set of regions found with 
#' \link{calculatePvalues}. It can further calculate the mean coverage per 
#' sample for each region.
#' 
#' @param fullCov A list where each element is the result from 
#' \link{loadCoverage} used with \code{returnCoverage = TRUE}. Can be generated 
#' using \link{fullCoverage}.
#' @param regions The \code{$regions} output from \link{calculatePvalues}. It 
#' is important that the seqlengths information is provided.
#' @param totalMapped The total number of reads mapped for each sample. 
#' Providing this data adjusts the coverage to reads in \code{targetSize} 
#' library. By default, to reads per 80 million reads.
#' @param targetSize The target library size to adjust the coverage to. Used
#' only when \code{totalMapped} is specified.
#' @param mc.cores This argument is passed to \link[BiocParallel]{SnowParam} 
#' to define the number of \code{workers}. You should use at most one core per 
#' chromosome.
#' @param mc.outfile This argument is passed to \link[BiocParallel]{SnowParam} 
#' to specify the \code{outfile} for any output from the workers.
#' @param chrsStyle The naming style of the chromosomes. By default, UCSC. See 
#' \link[GenomeInfoDb]{seqlevelsStyle}.
#' @param verbose If \code{TRUE} basic status updates will be printed along the 
#' way.
#'
#' @return a list of data.frame where each data.frame has the coverage 
#' information (nrow = width of region, ncol = number of samples) for a given 
#' region. The names of the list correspond to the region indexes in 
#' \code{regions}
#' 
#' @author Andrew Jaffe, Leonardo Collado-Torres
#' @seealso \link{fullCoverage}, \link{calculatePvalues}
#' @export
#' @importFrom GenomicRanges seqnames
#' @importFrom GenomeInfoDb seqlevelsStyle 'seqlevelsStyle<-'
#' mapSeqlevels
#' @importMethodsFrom GenomicRanges names 'names<-' length '[' coverage sort 
#' width c '$'
#' @importMethodsFrom IRanges subset as.data.frame as.factor
#' @importFrom IRanges IRanges
#' @importFrom BiocParallel SnowParam SerialParam bpmapply
#'
#' @details When \code{fullCov} is the output of \link{loadCoverage} with
#' \code{cutoff} non-NULL, \link{getRegionCoverage} assumes that the regions
#' come from the same data. Meaning that \link{filterData} was not used again.
#' This ensures that the regions are a subset of the data available in 
#' \code{fullCov}.
#' 
#'
#' @examples
#' ## Obtain fullCov object
#' fullCov <- list('21'=genomeDataRaw$coverage)
#' 
#' ## Assign chr lengths using hg19 information, use only first two regions
#' library('GenomicRanges')
#' data(hg19Ideogram, package = 'biovizBase', envir = environment())
#' regions <- genomeRegions$regions[1:2]
#' seqlengths(regions) <- seqlengths(hg19Ideogram)[names(seqlengths(regions))]
#'
#' ## Finally, get the region coverage
#' regionCov <- getRegionCoverage(fullCov=fullCov, regions=regions)

getRegionCoverage <- function(fullCov, regions, totalMapped = NULL, 
    targetSize = 80e6, mc.cores = 1,
    mc.outfile = Sys.getenv('SGE_STDERR_PATH'), chrsStyle = "UCSC",
    verbose = TRUE) {
    
    names(regions) <- seq_len(length(regions))  # add names
    
    ## Use UCSC style names by default
    names(fullCov) <- mapSeqlevels(names(fullCov), chrsStyle)
    seqlevelsStyle(regions) <- chrsStyle
        
    # split by chromosome
    regions.chrs <- as.factor(seqnames(regions))
    ## Make sure the order matches the one from the fullCov names
    regions.chrs <- factor(regions.chrs, levels = names(fullCov))
    grl <- split(regions, regions.chrs)  
    
    ## Define args
    moreArgs <- list(totalMapped = totalMapped, verbose = verbose)
    
    ## Define cluster
    if(mc.cores > 1) {
        BPPARAM <- SnowParam(workers = mc.cores, outfile = mc.outfile)
    } else {
        BPPARAM <- SerialParam()
    }
    
    counts <- bpmapply(function(chr, covInfo, g, totalMapped, verbose) {
        
        ## Parallel by chr, so no point in using mc.cores beyond the number of chrs
        if (verbose) 
            message(paste(Sys.time(), "getRegionCoverage: processing", chr))
        
        ## Check whether fullCov has been filtered, then subset
        if(all(c("coverage", "position") %in% names(covInfo))) {
            yy <- covInfo$coverage[IRanges(start = g$indexStart, end = g$indexEnd), ]
        } else {
            yy <- covInfo[ranges(g), ]  # better subset
        }
            
        # depth-adjust, like for plotting
        if (!is.null(totalMapped) & targetSize != 0) {
            yy <- DataFrame(mapply(function(x, d) x / d, 
                yy, totalMapped / targetSize))
        }
        
        ind <- rep(names(g), width(g))  # to split along
        ind <- factor(ind, levels = unique(ind))  # make factor in order
        # split(yy,ind) # 'CompressedSplitDataFrameList', faster but
        # less clear how to unlist below, so leave out
        res <- split(as.data.frame(yy), ind)
        
        if (verbose) 
            message(paste(Sys.time(), "getRegionCoverage: done processing", 
                chr))
                
        ## Done
        return(res)
    }, names(fullCov), fullCov, grl, MoreArgs = moreArgs, BPPARAM = BPPARAM,
    SIMPLIFY = FALSE)
    covList <- do.call("c", counts)  # collect list elements into one large list
    
    # put in original order
    names(covList) <- sapply(strsplit(names(covList), "\\."), 
        "[", 2)
    theData <- covList[order(as.numeric(names(covList)))]
    
    if (sum(sapply(theData, nrow)) != sum(width(regions))) {
        stop("The total width of the regions did not match with the dimensions of the extracted coverage data.")
    }
    
    return(theData)
} 
