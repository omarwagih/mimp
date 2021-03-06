BASE_DIR = system.file("extdata", "", package = "rmimp")


require(GenomicRanges)
require(data.table)
require(Biostrings)
require(parallel)

# if(T){
#   setwd('~/Development/rmimp/')
#   source('R/display-functions.r')
#   source('R/io-functions.r')
#   source('R/pwm-functions.r')
#   BASE_DIR = '~/Development/rmimp/inst/extdata/'
#   writeLines('Warning: remove base dir')
# }

# Current version
.MIMP_VERSION = '1.2'

# This message appears on library or require call of package
.onAttach <- function(lib, pkg, ...) {
  packageStartupMessage(sprintf("MIMP v%s (%s)
Type '?mimp' for help or see the documentation 'help(package=rmimp)' for more details

If you use MIMP in your research, please cite:
Wagih O, Reimand J, Bader GD (2015). MIMP: predicting the impact of mutations on kinase-substrate phosphorylation. Nat. Methods 12(6):531-3. doi:10.1038/nmeth.3396", .MIMP_VERSION, format(Sys.Date(), '%Y')))
}

#' Converts all columns of a data frame of class factor to character
#'
#' @param string String to be manipulated
#' @keywords internal factor character
#' 
#' @examples
#' unfactor( data.frame(x=c('A', 'B')) )
unfactor <- function(df){
  i <- sapply(df, is.factor)
  df[i] <- lapply(df[i], as.character)
  df
}


#' Get flanking sequences of a position.
#'
#' This function obtains the flanking sequence at one or more position. 
#' Out of bound indices are replaced by a blank character. 
#'
#' @param seqs Character vector of sequences. If only one sequence is provided, 
#'    indices from \code{inds} are assumed to all be from the same sequence. 
#' @param inds Numerical vector of positions corresponding to the sequences provided in \code{seqs}. 
#' @param flank Value indicating the number of characters to extract, before and after an index
#' @param empty_char Character used to replace out of bound flanking sequences
#' @keywords internal flank sequence
#' 
#' @examples
#' # One sequence and one index. Central character is 'B'
#' flankingSequence(seqs='ABC', inds=2, flank=1)
#' # An example showing the use of empty.char 
#' flankingSequence(seqs='ABC', inds=2, flank=5)
#' # An example with multiple sequences and indices
#' flankingSequence(seqs=c('ABC', 'XYZ'), inds=c(2, 1), flank=1)
flankingSequence <- function(seqs, inds, flank=7, empty_char='-'){
  if(length(seqs) == 1 & length(inds) >= length(seqs)) seqs = rep(seqs, length(inds))
  if(length(seqs) != length(inds)) stop('Length of sequences must be equal to length of positions')
  
  border = paste0(rep(empty_char, flank), collapse="")
  seqs = paste0(border, unlist(seqs, F, F), border)
  substr(seqs, inds, inds+(flank*2))
}

#' Find phosphorylation related variants (pSNVs)
#' 
#' Given mutation data and psites, find variants that
#' exist in the flanking regions of the psite
#'
#' @param muts Mutation data as data frame of two columns (1) name of gene or protein
#'    (2) mutation in the format X123Y, where X is the reference amino acid
#'    and Y is the alternative amino acid.
#' @param psites Phosphorylation data as a data frame of two columns (1) name of gene 
#'    or protein (2) Position of the phosphorylated residue
#' @param seqs Sequence data as a name list. Names of the list correspond to the gene or 
#'    protein name. Each entry contains the collapsed sequence.
#' @param flank Number of amino acids flanking the psite to be considered
#' 
#' @keywords internal psnv psites mutation snp
#' 
#' @import GenomicRanges
#' @importFrom IRanges IRanges
#' @examples
#' # No examples
pSNVs <- function(md, pd, seqdata, flank=7){
  
  md2 = md; pd2 = pd
  
  # Create psite and mutation Granges
  ps_gr = with(pd, GRanges(gene, IRanges(pos-flank, pos+flank))) 
  mt_gr = with(md, GRanges(gene, IRanges(mut_pos, mut_pos))) 
  
  # Find overlaps of mutations and psites
  ol = findOverlaps(mt_gr, ps_gr)
  
  if(!is.null(seqdata)){
    # Get flanking sequence from fasta file
    pd2$mt = pd2$wt = flankingSequence(seqdata[pd2$gene], pd2$pos, flank)
  }else{
    # We're processing psp data
    pd2$mt = pd2$wt = pd2$seq
  }
  
  df = cbind(pd2[subjectHits(ol),], md[queryHits(ol),])
  df$start = start(ps_gr[subjectHits(ol)])
  df$psite_pos = df$pos
  df$mut_dist = df$mut_pos - df$pos
  
  # Mutate mt sequence
  df$rel_ind = df$mut_pos - df$start + 1
  
  # Don't keep anything that doesnt match amino acid provided by user and amino acid in sequence
  seq_ref = base::substr(df$mt, df$rel_ind, df$rel_ind)
  df = subset(df, ref_aa == seq_ref)
  
  # Mutate
  base::substr(df$mt, df$rel_ind, df$rel_ind) = df$alt_aa
  
  
  if(is.null(seqdata)) df$gene = sprintf('%s (%s)', df$gene, df$symbol)
  
  df = df[,!names(df) %in% c('pos', 'start', 'end', 'gene.1', 'seq', 'symbol', 'rel_ind')]
  rownames(df) = NULL
  df
}



#' Compute likelihood using probability density function
#' 
#' @param p scores
#' @param params parameters of GMM from getParams
#' @keywords internal
.probPoint = function(p, params) {
  # For all points, get likeli hood for each component
  component_vals = apply(params, 1, function(r){
    dnorm(p, mean = r['means'], sd = r['sds'], log=F) * r['wts']
  })
  
  if(length(p) == 1) return(sum(component_vals))
  # Summ accross all components
  apply(component_vals, 1, sum)
}

#' Computing posterior probability - ploss and pgain
#' 
#' @param wt.scores Wild type score
#' @param mt.scores Mutant score
#' @param fg.params Distribution parameters of GMMs (foreground). This is precomputed and comes built into mimp.
#' @param bg.params Distribution parameters of GMMs (background). This is precomputed and comes built into mimp.
#' @param auc AUC of the model. This is precomputed and comes built into mimp.
#' @param intermediate If TRUE, intermediate likelihoods used to compute ploss and pgain is returned. Otherwise only ploss and pgain returned
#' @keywords internal
pRewiringPosterior <- function(wt.scores, mt.scores, fg.params, bg.params, auc=1, intermediate=F){
  
  fg_prior = auc/(1+auc)
  bg_prior = 1-fg_prior
  
  # Get probability of wt in fg/bg
  l.wt.fg = .probPoint(wt.scores, fg.params) * fg_prior
  l.wt.bg = .probPoint(wt.scores, bg.params) * bg_prior
  
  # Get wt posteriors 
  post.wt.fg = (l.wt.fg) / (l.wt.bg + l.wt.fg)
  post.wt.bg = (l.wt.bg) / (l.wt.bg + l.wt.fg)
  
  if(missing(mt.scores))
    return(data.frame(l.wt.fg, l.wt.bg, post.wt.fg, post.wt.bg))
  
  
  # Get probability of mt in fg/bg
  l.mt.fg = .probPoint(mt.scores, fg.params) * fg_prior
  l.mt.bg = .probPoint(mt.scores, bg.params) * bg_prior
  
  # Get mt posteriors
  post.mt.fg = (l.mt.fg) / (l.mt.bg + l.mt.fg)
  post.mt.bg = (l.mt.bg) / (l.mt.bg + l.mt.fg)
  
  post.wt.fg[is.na(post.wt.fg)] = 0
  post.mt.bg[is.na(post.mt.bg)] = 1
  post.wt.bg[is.na(post.wt.bg)] = 1
  post.mt.fg[is.na(post.mt.fg)] = 0
  
  # Get probabilities of loss and gain
  ploss = post.wt.fg * post.mt.bg
  pgain = post.wt.bg * post.mt.fg
  
  if(intermediate){
    return(data.frame(l.wt.fg, l.mt.fg, l.wt.bg, l.mt.bg, 
                      post.wt.fg, post.mt.fg, post.wt.bg, post.mt.bg, 
                      ploss, pgain))
  }
  data.frame(ploss, pgain)
}


#' Score wt and mt sequences for a pwm
#'
#' @param obj MIMP kinase object containing PWM, auc, GMM parameters, family name, etc.
#' @param mut_ps psnvs data frame containing wt and mt sequences computed from pSNVs function
#' @param prob.thresh Probability threshold of gains and losses. This value should be between 0.5 and 1.
#' @param log2.thresh Threshold for the absolute value of log ratio between wild type and mutant scores. Anything less than this value is discarded (default: 1).
#' @param include.cent If TRUE, gains and losses caused by mutation in the central STY residue are kept
#' 
#' @keywords internal mut psites score snp snv
computeRewiring <- function(obj, mut_ps, prob.thresh=0.5, log2.thresh=1, include.cent=F, 
                            degenerate.pwms=F, .degenerate.groups=c('DE','KR','ILMV')){
  
  # Score wild type and mutant sequences
  pwm = obj$pwm
  
  # make PWM degenerate if needed
  if(degenerate.pwms) pwm = degeneratePWM(pwm, .degenerate.groups)
  mut_ps$score_wt = mss(mut_ps$wt, pwm)
  mut_ps$score_mt = mss(mut_ps$mt, pwm)
  
  # Remove cases where wt and mt are NA
  #mut_ps = mut_ps[!(is.na(mut_ps$score_wt) & is.na(mut_ps$score_mt)),]
  mut_ps = subset(mut_ps, !(is.na(score_wt) & is.na(score_mt)) )
  
  # Do we have any data left?
  if(nrow(mut_ps) == 0) return(NULL)
  
  # Compute the log2 ratio
  mut_ps$log_ratio = with(mut_ps, log2(score_mt/score_wt) )
  
  # Set the kinase name, family and number of sequences used to build the model
  mut_ps$pwm = obj$name
  mut_ps$pwm_fam = obj$family
  mut_ps$nseqs = attr(obj$pwm, 'nseqs')
  
  res = pRewiringPosterior(mut_ps$score_wt, mut_ps$score_mt, obj$fg.params, obj$bg.params, obj$auc)
  
  # Filter by probability threshold
  ind = with(res, ploss >= prob.thresh | pgain >= prob.thresh)
  
  # Nothing passes the prob threshold, return NULL
  if(sum(ind) == 0) return(NULL)
  
  # Join with main data frame
  mut_ps = cbind(mut_ps[ind,], res[ind,])
  
  # Filter by log2 ratio, things with NAs have no log ratio
  mut_ps = subset(mut_ps, is.na(log_ratio) | abs(log_ratio) >= log2.thresh)
  
  # Nothing passes the log2 ratio, return null
  if(nrow(mut_ps) == 0) return(NULL)
  
  # Set the effect
  effect = rep('gain', nrow(mut_ps))
  effect[mut_ps$ploss >= prob.thresh] = 'loss'
  
  # Set prob as maximum of ploss and pgain
  mut_ps$prob = pmax(mut_ps$ploss, mut_ps$pgain)
  mut_ps$effect = effect
  
  # Remove ploss pgain. Retain only 'prob'
  mut_ps = mut_ps[,!names(mut_ps) %in% c('ploss', 'pgain')]
  
  return(mut_ps)
}

#' Predict the impact of single variants on phosphorylation.
#'
#' This function takes in mutation, sequence and phosphorylation data to predict the 
#' impact the mutation has on phosphorylation.
#' 
#' @param muts Mutation data file: a space delimited text file OR data frame containing two columns (1) gene and (1) mutation. 
#' Example:
#' \tabular{ll}{
#'    TP53 \tab R282W\cr
#'    CTNNB1 \tab S33C\cr
#'    CTNNB1 \tab S37F\cr
#' }
#' @param seqs Sequence data file containing protein sequences in FASTA format OR 
#'  named list of sequences where each list element is the uppercase sequence and the 
#'  name of each element is that of the protein. Example: list(GENEA="ARNDGH", GENEB="YVRRHS")
#'  If both sequences and phosphosites are omitted, mimp will use sites from phosphositeplus. 
#'  This means the IDs in your mutation file must be UniProt accession numbers
#' @param psites Phosphorylation data file (optional): a space delimited text file OR data frame containing  two columns (1) gene and (1) positions of phosphorylation sites. Example:
#' \tabular{ll}{
#'    TP53 \tab 280\cr
#'    CTNNB1 \tab 29\cr
#'    CTNNB1 \tab 44\cr
#' }
#' If both sequences and phosphosites are omitted, mimp will use sites from phosphositeplus. 
#' This means the IDs in your mutation file must be UniProt accession numbers
#' @param prob.thresh Probability threshold of gains and losses. This value should be between 0.5 and 1.
#' @param log2.thresh Threshold for the absolute value of log ratio between wild type and mutant scores. Anything less than this value is discarded (default: 1).
#' @param display.results If TRUE results are visualised in an html document after analysis is complete
#' @param include.cent If TRUE, gains and losses caused by mutation in the central STY residue are kept. Scores of peptides with a non-STY central residue is given a score of 0 (default: FALSE).
#' @param model.data Name of specificity model data to use, can be "hconf" : individual experimental kinase specificity models used to scan for rewiring events. For experimental kinase specificity models, grouped by family, set to "hconf-fam". Both are considered high confidence. For lower confidence predicted specificity models , set to "lconf". NOTE: Predicted models are purely speculative and should be used with caution
#' @param cores Number of cores to use - default is 1. More cores will speed up computation.
#' @param kinases Character vector of kinase models to be used - if missing all kinase models are used (default)
#' 
#' @return 
#' The data is returned in a \code{data.frame} with the following columns:
#' \item{gene}{Gene with the rewiring event}
#' \item{mut}{Mutation causing the rewiring event}
#' \item{psite_pos}{Position of the phosphosite}
#' \item{mut_dist}{Distance of the mutation relative to the central residue}
#' \item{wt}{Sequence of the wildtype phosphosite (before the mutation). Score is NA if the central residue is not S, T or Y}
#' \item{mt}{Sequence of the mutated phosphosite (after the mutation). Score is NA if the central residue is not S, T or Y}
#' \item{score_wt}{Matrix similarity score of the wildtype phosphosite}
#' \item{score_mt}{Matrix similarity score of the mutated phosphosite}
#' \item{log_ratio}{Log2 ratio between mutant and wildtype scores. A high positive log ratio represents a high confidence gain-of-phosphorylation event. A high negative log ratio represents a high confidence loss-of-phosphorylation event. This ratio is NA for mutations that affect the central phosphorylation sites}
#' \item{pwm}{Name of the kinase being rewired}
#' \item{pwm_fam}{Family/subfamily of kinase being rewired. If a kinase subfamily is available the family and subfamily will be separated by an underscore e.g. "DMPK_ROCK". If no subfamily is available, only the family is shown e.g. "GSK"}
#' \item{nseqs}{Number of sequences used to construct the PWM. PWMs constructed with a higher number of sequences are generally considered of better quality.}
#' \item{prob}{Joint probability of wild type sequence belonging to the foreground distribution and mutated sequence belonging to the background distribution, for loss and vice versa for gain.}
#' \item{effect}{Type of rewiring event, can be "loss" or "gain"}
#' 
#' 
#' @keywords mimp psites mutation snp snv pwm rewiring phosphorylation kinase
#' @importFrom parallel mclapply
#' @importFrom data.table rbindlist
#' 
#' @export
#' @examples
#' # Get the path to example phosphorylation data 
#' psite.file = system.file("extdata", "sample_phosphosites.tab", package = "rmimp")
#' 
#' # Get the path to example mutation data 
#' mut.file = system.file("extdata", "sample_muts.tab", package = "rmimp")
#' 
#' # Get the path to example FASTA sequence data 
#' seq.file = system.file("extdata", "sample_seqs.fa", package = "rmimp")
#' 
#' # Run rewiring analysis
#' results = mimp(mut.file, seq.file, psite.file, display.results=TRUE)
#' 
#' # Show head of results
#' head(results)
mimp <- function(muts, seqs=NULL, psites=NULL, prob.thresh=0.5, log2.thresh=1, 
                 display.results=F, include.cent=F, model.data='hconf', cores=1,
                 kinases){
  
  # Constant - do not change
  flank=7
  
  # Ensure valid thresholds
  if(!is.numeric(prob.thresh) | prob.thresh > 1 | prob.thresh < 0) 
    stop('Probability threshold "prob.thresh" must be between 0.5 and 1')
  
  # Are we using phosphositeplus sites?
  use_psp = is.null(seqs)
  # Read in data
  seqdata = NULL
  if(!use_psp) seqdata = .readSequenceData(seqs)
  md = .readMutationData(muts, seqdata)
  pd = .readPsiteData(psites, seqdata)
  
  # Keep only genes we have data for
  md = md[md$gene %in% pd$gene,]
  
  if(!use_psp){
    seqdata = seqdata[names(seqdata) %in% pd$gene]
    
    # Validate that mutations mapp to the correct residue
    .validateMutationMapping(md, seqdata)
    
    # If we have nothing left, throw a warning and return NULL
    if(nrow(pd) == 0 | nrow(md) == 0 | length(seqdata) == 0){
      warning('No phosphorylation, mutation or sequence data remaining after filtering!')
      return(NULL)
    }
    
    # Ensure psite positions map to an S, T or Y
    .validatePsitesSTY(pd, seqdata)
  }else{
    
    # We are using phosphositeplus data
    pd = subset(pd, gene %in% unique(md$gene))
  }
  
  
  # Get mutations in flanking regions of psites
  mut_psites = pSNVs(md, pd, seqdata, flank)
  
  
  # Are we keeping central residues?
  if(!include.cent) mut_psites = subset(mut_psites, mut_dist != 0)
  
  # If no mutations map, throw warning and return NULL
  if(nrow(mut_psites) == 0){
    warning('No pSNVs were found!')
    return(NULL)
  }
  
  # Get data 
  cat('\r.... | loading specificity models')
  mpath = .getModelDataPath(model.data)
  model.data = mpath$id
  mdata = readRDS(mpath$path)
  cat('\rdone\n')
  
  # If we're missing kinase names
  if(missing(kinases)) kinases = names(mdata)
  
  # Throw error if invalid kinase names
  kinases = intersect(kinases, names(mdata))
  if(length(kinases) == 0) 
    stop(sprintf('Invalid kinase names. Please choose from the following: %s', 
                 paste(names(mdata), collapse=',')))
  
  mdata = mdata[kinases]
  
  # Print for multicore
  if(cores > 1) cat('\r.... | predicting kinase rewiring events')
  
  scored = mclapply(X=1:length(mdata), mc.cores = cores, FUN=function(i){
    # Processing PWM i
    obj = mdata[[i]]
    
    # Print msg
    if(cores == 1){
      perc = round((i/length(mdata))*100)
      cat(sprintf('\r%3d%% | predicting kinase rewiring events', perc))
    }
    
    computeRewiring(obj, mut_psites, prob.thresh, log2.thresh, include.cent)
  })
  cat('\rdone\n')
  
  # Check if we have any data left
  scored = scored[!sapply(scored, is.null)]
  if(length(scored) == 0){
    warning("No rewiring events found, returning NULL")
    return(NULL)
  }
  
  # Merge all data frames
  scored_final = rbindlist(scored)
  scored_final = scored_final[order(prob, decreasing=T),]
  scored_final = as.data.frame(scored_final)
  
  attr(scored_final, 'model.data') = model.data
  
  if(display.results) results2html(scored_final)
  
  # Remove useless columns, reset attributes and return
  cat(sprintf('\rdone | analysis complete with a total of %s predicted rewiring events\a\n', nrow(scored_final)))
  scored_final = scored_final[,!names(scored_final) %in% c('ref_aa', 'alt_aa', 'mut_pos')]
  attr(scored_final, 'model.data') = model.data
  
  return(scored_final)
}



#' Compute posterior probability of wild type phosphosites for kinases 
#' 
#' @param psites phosphorylation data, see \code{?mimp} for details
#' @param seqs sequence data, see \code{?mimp} for details
#' @param model.data MIMP model used, see \code{?mimp} for details
#' @param posterior_thresh posterior probability threshold that the score belongs to the foreground distribution of the kinase, probabilities below this value are discarded (default 0.8)
#' @param intermediate if TRUE intermediate MSS scores and likelihoods are reported (default FALSE)
#' @param kinases vector of kinases used for the scoring (e.g. c("AURKB", "CDK2")), if this isn't provided all kinases will be used .
#' 
#' @export
#' @return
#' The data is returned in a \code{data.frame} with the following columns:
#' \item{gene}{Gene with the rewiring event}
#' \item{pos}{Position of the phosphosite}
#' \item{wt}{Sequence of the wildtype phosphosite}
#' \item{score_wt}{(intermediate value) matrix similarity score of sequence}
#' \item{l.wt.fg}{(intermediate value) likelihood of score given foreground distribution}
#' \item{l.wt.bg}{(intermediate value) likelihood of score given background distribution}
#' \item{post.wt.fg}{posterior probability of score in foreground distribution}
#' \item{post.wt.bg}{posterior probability of score in background distribution}
#' \item{pwm}{Name of the predicted kinase}
#' \item{pwm_fam}{Family/subfamily of the predicted kinase. If a kinase subfamily is available the family and subfamily will be seprated by an underscore e.g. "DMPK_ROCK". If no subfamily is available, only the family is shown e.g. "GSK"}
#' 
#' @importFrom data.table rbindlist 
#' 
#' If no predictions were made, function returns NULL
#' @examples
#' # Get the path to example phosphorylation data 
#' psite.file = system.file("extdata", "sample_phosphosites.tab", package = "rmimp")
#' 
#' # Get the path to example FASTA sequence data 
#' seq.file = system.file("extdata", "sample_seqs.fa", package = "rmimp")
#' 
#' # Run for all kinases
#' results_all = predictKinasePhosphosites(psite.file, seq.file)
#' 
#' # Run for select kinases
#' results_select = predictKinasePhosphosites(psite.file, seq.file, kinases=c("AURKB", "CDK2"))
predictKinasePhosphosites <- function(psites, seqs, model.data='hconf', posterior_thresh=0.8, intermediate=F, kinases){
  flank = 7
  # Read data
  seqdata = .readSequenceData(seqs)
  pd = .readPsiteData(psites, seqdata)
  
  # Get flanking sequence
  pd$wt = flankingSequence(seqdata[pd$gene], pd$pos, flank)
  seqdata = seqdata[names(seqdata) %in% pd$gene]
  
  # If we have nothing left, throw a warning and return NULL
  if(nrow(pd) == 0 | length(seqdata) == 0){
    warning('No phosphorylation or sequence data remaining after filtering!')
    return(NULL)
  }
  
  # Ensure psite positions map to an S, T or Y
  .validatePsitesSTY(pd, seqdata)
  
  # Get data 
  cat('\r.... | loading specificity models')
  mdata = readRDS(.getModelDataPath(model.data)$path)
  cat('\rdone\n')
  
  # If we're missing kinase names
  if(missing(kinases)) kinases = names(mdata)
  
  # Throw error if invalid kinase names
  kinases = intersect(kinases, names(mdata))
  if(length(kinases) == 0) 
    stop(sprintf('Invalid kinase names. Please choose from the following: %s', 
                 paste(names(mdata), collapse=',')))
  
  # Score!
  scored = lapply(1:length(kinases), function(i){
    kin = kinases[i]
    # Processing PWM i
    obj = mdata[[kin]]
    # Print msg
    perc = round((i/length(kinases))*100)
    cat(sprintf('\r%3d%% | scoring sequences', perc))
    
    # PWM scores
    pwm_scores = mss(pd$wt, obj$pwm)
    
    # Get posteriors
    post = pRewiringPosterior(wt.scores = pwm_scores,
                              fg.params = obj$fg.params, 
                              bg.params = obj$bg.params)
    
    # Attach mss score too
    post = cbind(mss=pwm_scores, post)
    # Set posteriors that have NA (ST vs Y) to -1 for filtering
    post$post.wt.fg[is.na(post$post.wt.fg)] = -1
    
    # Pick only those that pass the threshold
    ind = post$post.wt.fg >= posterior_thresh
    
    # Bind with phosphosite information
    z = cbind(pd[ind,], post[ind,])
    if(nrow(z) == 0) return(NULL)
    
    z$pwm = obj$name
    z$pwm_fam = obj$family
    z
  })
  
  cat('\rdone\n')
  
  # Remove null objects
  scored = scored[!sapply(scored, is.null)]
  if(length(scored) == 0) return(NULL)
  
  # Rbind everything
  final = as.data.frame( rbindlist(scored) )
  rownames(final) = NULL
  
  # Keep intermediates?
  if(!intermediate) final = final[,!names(final) %in% c('mss', 'l.wt.fg', 'l.wt.bg')]
  
  final
}

