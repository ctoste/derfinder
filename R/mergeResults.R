#' Merge results from different chromosomes
#'
#' This function merges the results from running \link{analyzeChr} on several 
#' chromosomes and assigns genomic states using \link{annotateRegions}. It 
#' re-calculates the p-values and q-values using the pooled areas from the null 
#' regions from all chromosomes. Once the results have been merged, 
#' \code{derfinderReport::generateReport} can be used to generate an HTML 
#' report of the results. The \code{derfinderReport} package is available at 
#' https://github.com/lcolladotor/derfinderReport.
#' 
#' @param chrs The chromosomes of the files to be merged.
#' @param prefix The main data directory path, which can be useful if 
#' \link{analyzeChr} is used for several parameters and the results are saved 
#' in different directories.
#' @param significantCut A vector of length two specifiying the cutoffs used to 
#' determine significance. The first element is used to determine significance 
#' for the p-values and the second element is used for the q-values just like 
#' in \link{calculatePvalues}.
#' @param genomicState This argument is passed to \link{annotateRegions}.
#' @param minoverlap This argument is passed to \link{annotateRegions}.
#' @param fullOrCoding This argument is passed to \link{annotateRegions}.
#' @param mergePrep If \code{TRUE} the output from \link{preprocessCoverage} is 
#' merged. 
#' @param chrsStyle The naming style of the chromosomes. By default, UCSC. See 
#' \link[GenomeInfoDb]{seqlevelsStyle}.
#' @param verbose If \code{TRUE} basic status updates will be printed along the 
#' way.
#'
#' @return Seven Rdata files.
#' \describe{
#' \item{fullFstats.Rdata }{ Full F-statistics from all chromosomes in a list 
#' of Rle objects.}
#' \item{fullTime.Rdata }{ Timing information from all chromosomes.}
#' \item{fullNullSummary.Rdata}{ A DataFrame with the null region information: 
#' statistic, width, chromosome and permutation identifier. It's ordered by the 
#' statistics}
#' \item{fullRegions.Rdata}{ GRanges object with regions found and with full 
#' annotation from \link[bumphunter]{annotateNearest}. Note that the column 
#' \code{strand} from \link[bumphunter]{annotateNearest} is renamed to 
#' \code{annoStrand} to comply with GRanges specifications. }
#' \item{fullCoveragePrep.Rdata}{ A list with the pre-processed coverage data 
#' from all chromosomes.}
#' \item{fullAnnotatedRegions.Rdata}{ A list as constructed in 
#' \link{annotateRegions} with the assigned genomic states.}
#' \item{optionsMerge.Rdata}{ A list with the options used when merging the 
#' results. Used in \code{derfinderReport::generateReport}.}
#' }
#'
#' @author Leonardo Collado-Torres
#' @seealso \link{analyzeChr}, \link{calculatePvalues}, \link{annotateRegions}
#' @export
#' @importFrom GenomicRanges GRangesList
#' @importMethodsFrom GenomicRanges '$' '$<-' '['
#' @importFrom IRanges DataFrame RleList
#' @importMethodsFrom IRanges cbind values 'values<-' '[' '$' '$<-' length 
#' order unlist as.numeric nrow
#' @importFrom qvalue qvalue
#' @importFrom GenomeInfoDb mapSeqlevels
#'
#' @examples
#' ## The output will be saved in the 'generateReport-example' directory
#' dir.create('generateReport-example', showWarnings = FALSE, recursive = TRUE)
#' 
#' ## For convenience, the derfinder output has been pre-computed
#' file.copy(system.file(file.path('extdata', 'chr21'), package='derfinder', 
#' mustWork=TRUE), 'generateReport-example', recursive=TRUE)
#' 
#' \dontrun{
#' ## If you prefer, you can generate the output from derfinder
#' initialPath <- getwd()
#' setwd(file.path(initialPath, 'generateReport-example'))
#'
#' ## Collapse the coverage information
#' collapsedFull <- collapseFullCoverage(list(genomeData$coverage), 
#' verbose=TRUE)
#' 
#' ## Calculate library size adjustments
#' sampleDepths <- sampleDepth(collapsedFull, probs=c(0.5), nonzero=TRUE, 
#' verbose=TRUE)
#' 
#' ## Build the models
#' group <- genomeInfo$pop
#' adjustvars <- data.frame(genomeInfo$gender)
#' models <- makeModels(sampleDepths, testvars=group, adjustvars=adjustvars)
#'
#' ## Analyze chromosome 21
#' analyzeChr(chr='21', coverageInfo=genomeData, models=models, 
#' cutoffFstat=1, cutoffType='manual', seeds=20140330, groupInfo=group, 
#' mc.cores=1, writeOutput=TRUE, returnOutput=FALSE)
#'
#' ## Change the directory back to the original one
#' setwd(initialPath)
#' }
#'
#' ## Merge the results from the different chromosomes. In this case, there's 
#' ## only one: chr21
#' mergeResults(chrs='21', prefix='generateReport-example', 
#' genomicState=genomicState)
#'
#' \dontrun{
#' ## You can then explore the wallclock time spent on each step
#' load(file.path('generateReport-example', 'fullRegions.Rdata'))
#' 
#' ## Process the time info
#' time <- lapply(fullTime, function(x) data.frame(diff(x)))
#' time <- do.call(rbind, time)
#' colnames(time) <- 'sec'
#' time$sec <- as.integer(round(time$sec))
#' time$min <- time$sec / 60
#' time$chr <- paste0('chr', gsub('\\..*', '', rownames(time)))
#' time$step <- gsub('.*\\.', '', rownames(time))
#' rownames(time) <- seq_len(nrow(time))
#' 
#' ## Make plot
#' library('ggplot2')
#' ggplot(time, aes(x=step, y=min, colour=chr)) + geom_point() + 
#'     labs(title='Wallclock time by step') + 
#'     scale_colour_discrete(limits=chrs) + 
#'     scale_x_discrete(limits=names(fullTime[[1]])[-1]) + ylab('Time (min)') + 
#'     xlab('Step')
#' }

mergeResults <- function(chrs = c(1:22, "X", "Y"), prefix = ".", 
    significantCut = c(0.05, 0.1), genomicState, minoverlap = 20, 
    fullOrCoding = "full", mergePrep = FALSE, chrsStyle = "UCSC", 
    verbose = TRUE) {
    ## For R CMD check
    prep <- fstats <- regions <- annotation <- timeinfo <- NULL
    
    ## Use UCSC names by default
    chrs <- mapSeqlevels(chrs, chrsStyle)
    
    ## save merging options used
    optionsMerge <- list(chrs = chrs, significantCut = significantCut, 
        minoverlap = minoverlap, mergeCall = match.call())
    if (verbose) 
        message(paste(Sys.time(), "mergeResults: Saving options used"))
    save(optionsMerge, file = file.path(prefix, "optionsMerge.Rdata"))
    
    ## Initialize
    fullCoveragePrep <- fullTime <- fullNullPermutation <- fullNullWidths <- 
        fullNullStats <- fullFstats <- fullAnno <- fullRegs <- vector("list", 
        length(chrs))
    names(fullCoveragePrep) <- names(fullTime) <- names(fullNullPermutation) <-
        names(fullNullWidths) <- names(fullNullStats) <- names(fullFstats) <-
        names(fullAnno) <- names(fullRegs) <- chrs
    
    ## Actual processing
    for (chr in chrs) {
        if (verbose) 
            message(paste(Sys.time(), "Loading chromosome", chr))
        
        ## Process the F-statistics
        load(file.path(prefix, chr, "fstats.Rdata"))
        fullFstats[[chr]] <- fstats
        
        ## Process the regions, nullstats and nullwidths
        load(file.path(prefix, chr, "regions.Rdata"))
        fullRegs[[chr]] <- regions$regions
        fullNullStats[[chr]] <- regions$nullStats
        fullNullWidths[[chr]] <- regions$nullWidths
        fullNullPermutation[[chr]] <- regions$nullPermutation
        
        ## Process the annotation results
        load(file.path(prefix, chr, "annotation.Rdata"))
        fullAnno[[chr]] <- annotation
        
        ## Process the timing information
        load(file.path(prefix, chr, "timeinfo.Rdata"))
        fullTime[[chr]] <- timeinfo
        
        ## Process the covPrep data
        if (mergePrep) {
            load(file.path(prefix, chr, "coveragePrep.Rdata"))
            fullCoveragePrep[[chr]] <- prep
        }
    }
    
    ## Merge regions
    fullRegions <- unlist(GRangesList(fullRegs), use.names = FALSE)
    
    ## Process the annotation
    fullAnnotation <- do.call(rbind, fullAnno)
    if (!is.null(fullAnnotation)) {
        colnames(fullAnnotation)[which(colnames(fullAnnotation) == 
            "strand")] <- "annoStrand"
        rownames(fullAnnotation) <- NULL
        
        ## For some reason, signature 'AsIs' does not work when
        ## assigning the values() <-
        fullAnnotation$name <- as.character(fullAnnotation$name)
        fullAnnotation$annotation <- as.character(fullAnnotation$annotation)
        
        ## Combine regions with annotation
        values(fullRegions) <- cbind(values(fullRegions),
            DataFrame(fullAnnotation))
    }
    
    
    ## Summarize the null regions
    nulls <- unlist(RleList(fullNullStats), use.names = FALSE)
    widths <- unlist(RleList(fullNullWidths), use.names = FALSE)
    permutations <- unlist(RleList(fullNullPermutation), use.names = FALSE)
    howMany <- unlist(lapply(fullNullStats, length))
    
    if (length(nulls) > 0) {
        ## Proceed only if there are null regions to work with
        fullNullSummary <- DataFrame(stat = nulls, width = widths, 
            chr = Rle(names(fullNullStats), howMany),
            permutation = permutations)
        rm(nulls, widths, howMany, permutations)
        
        fullNullSummary$area <- abs(fullNullSummary$stat) * 
            fullNullSummary$width
        fullNullSummary <- fullNullSummary[order(fullNullSummary$area, 
            decreasing = TRUE), ]
    } else {
        fullNullSummary <- DataFrame(NULL)
    }
    
    if (verbose) 
        message(paste(Sys.time(), "mergeResults: Saving fullNullSummary"))
    save(fullNullSummary, file = file.path(prefix, "fullNullSummary.Rdata"))
    
    ## Re-calculate p-values and q-values
    if (verbose) 
        message(paste(Sys.time(), "mergeResults: Re-calculating the p-values"))
    
    if (nrow(fullNullSummary) > 0) {
        ## Actual calculation
        nullareas <- as.numeric(fullNullSummary$area)
        pvals <- sapply(fullRegions$area, function(x) {
            sum(nullareas > x)
        })
        fullRegions$significant <- factor(fullRegions$pvalues < 
            significantCut[1], levels = c(TRUE, FALSE))
        
        ## Update info
        fullRegions$pvalues <- (pvals + 1)/(length(nullareas) + 
            1)
        
        ## Sometimes qvalue() fails due to incorrect pi0 estimates
        qvalues <- qvalue(fullRegions$pvalues)
        if (is(qvalues, "qvalue")) {
            qvalues <- qvalues$qvalues
            sigQval <- factor(qvalues < significantCut[2], levels = c(TRUE, 
                FALSE))
        } else {
            qvalues <- rep(NA, length(fullRegions$pvalues))
            sigQval <- rep(NA, length(fullRegions$pvalues))
        }
        fullRegions$qvalues <- qvalues
        fullRegions$significantQval <- sigQval
    }
    ## Sort by decreasing area
    fullRegions <- fullRegions[order(fullRegions$area, decreasing = TRUE)]
    
    ## save GRanges version
    if (verbose) 
        message(paste(Sys.time(), "mergeResults: Saving fullRegions"))
    save(fullRegions, file = file.path(prefix, "fullRegions.Rdata"))
    
    ## Assign genomic states
    if (verbose) 
        message(paste(Sys.time(), "mergeResults: assigning genomic states"))
    fullAnnotatedRegions <- annotateRegions(regions = fullRegions, 
        genomicState = genomicState, minoverlap = minoverlap, 
        fullOrCoding = fullOrCoding, annotate = TRUE, verbose = verbose)
    
    if (verbose) 
        message(paste(Sys.time(), "mergeResults: Saving fullAnnotatedRegions"))
    save(fullAnnotatedRegions, file = file.path(prefix,
        "fullAnnotatedRegions.Rdata"))
    
    ## Save Fstats, Nullstats, and time info
    if (verbose) 
        message(paste(Sys.time(), "mergeResults: Saving fullFstats"))
    save(fullFstats, file = file.path(prefix, "fullFstats.Rdata"))
    
    if (verbose) 
        message(paste(Sys.time(), "mergeResults: Saving fullTime"))
    save(fullTime, file = file.path(prefix, "fullTime.Rdata"))
    
    if (mergePrep) {
        if (verbose) 
            message(paste(Sys.time(), "mergeResults: Saving fullCoveragePrep"))
        save(fullCoveragePrep, file = file.path(prefix,
            "fullCoveragePrep.Rdata"))
    }
    
    ## Finish
    return(invisible(NULL))
} 
