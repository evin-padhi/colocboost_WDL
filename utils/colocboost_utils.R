### Preprocessing functions

prep_covar_data <- function(QTL_covar_input){
covar_df <- QTL_covar_input %>%
    janitor::row_to_names(1) %>%
    filter(!is.na(ID)) %>%
    filter(!str_detect(ID,'batch')) %>%
    t() %>%
    data.frame() %>% rownames_to_column('ID') %>%
    janitor::row_to_names(1) %>% data.frame()

rownames(covar_df) <- NULL
output <- covar_df  %>%
    column_to_rownames('ID')
output
}

# residualizes phenotype data on covariates
residualize_molecular_phenotype_data <- function(phenotype_vector,covars_df){
joint_data <- phenotype_vector %>%
        data.frame() %>%
        rownames_to_column('ID') %>%
        left_join(covars_df %>% rownames_to_column('ID'),by = 'ID') %>%
        column_to_rownames('ID') %>%
        mutate(across(everything(),~as.numeric(.)))
regression_model <- lm(value ~ .,data = joint_data)
residual_data <- bind_cols(ID = rownames(joint_data),value = resid(regression_model)) %>% column_to_rownames('ID')
residual_data
}


residualize_genotype <- function(outcome_vector,predictor_df){
joint_data <- bind_cols(outcome = outcome_vector,predictor_df) %>% mutate(across(everything(),~as.numeric(.)))
regression_model <- lm(outcome_vector ~ .,data = joint_data)
residual_data <- resid(regression_model)
residual_data

}


# pulls out expression values for a given gene from a bed file
extract_phenotype_vector <- function(phenotype_bed_file,protein_name){
phenotype_data <- phenotype_bed_file %>% filter(gene_id == protein_name) %>%
        select(-`#chr`,-start,-end) %>%
        pivot_longer(!gene_id) %>%
        column_to_rownames('name') %>%
        select(-gene_id) %>%
        data.matrix()
phenotype_data
}

# uses the phenotype bed file to extract cis-window for gene of interest and
# gets all variants within that window from VCF file using tabix
extract_genotype_vector <- function(phenotype_bed_file,protein_name,tabix_path){
require(bedr)
input_range <- phenotype_bed_file %>%
    filter(gene_id == protein_name) %>%
    mutate(start = start -1000000,end = end + 1000000) %>%
    mutate(start = case_when(start  < 1 ~ 1,TRUE ~ start) ) %>%
    mutate(range = paste0(`#chr`,':',start,'-',end)) %>%
    pull(range)

tabix_res <- tabix(input_range[1],tabix_path)
tabix_res
}


clean_genotype_data <- function(tabix_output){
variant_metadata <- tabix_output %>%
        select(CHROM,POS,REF,ALT) %>%
        mutate(ID = paste0(CHROM,"-",POS,'-',REF,'-',ALT)) %>% select(ID)
genotype_matrix <- tabix_output %>%
        select(-CHROM,-POS,-ID,-REF,-ALT,-QUAL,-FILTER,-INFO,-FORMAT) %>%
        mutate(across(everything(),~str_remove(.,':.*')))  %>%
        mutate(across(everything(),~case_when(. == '0/0' ~ 0, . == '1/0' ~1,. == '0/1' ~1,. == '1/1' ~ 2,
                                              . == '0|0' ~ 0, . == '1|0' ~1,. == '0|1' ~1,. == '1|1' ~ 2)))

output_data <- bind_cols(variant_metadata,genotype_matrix) %>%
        column_to_rownames('ID') %>%
        t() %>%
        data.frame() %>%
        mutate(across(everything(),~scale(.))) %>%
        dplyr::rename_with(~str_replace_all(.,'\\.','-'))
output_data
}

# extracts variant metadata from genotype matrix to be used
# to query GWAS data
extract_variant_metadata <- function(genotype_matrix){
variant_data <- data.frame(variants = colnames(genotype_matrix)) %>%
        separate(variants, into = c('chromosome','pos','ref','alt')) %>%
        mutate(pos = as.numeric(pos))
variant_data

}

extract_GWAS_data <- function(variant_metadata,GWAS_sumstats){
GWAS_data <- variant_metadata %>%
    mutate(pos = as.numeric(pos)) %>%
    mutate(variant = paste0(chromosome,'-',pos,'-',ref,'-',alt)) %>%
    left_join(GWAS_sumstats,by = c('chromosome','pos' = 'base_pair_location') ) %>%
    select(variant,beta,standard_error,n) %>%
    dplyr::rename('sebeta' = 'standard_error')
GWAS_data
}



# preps individual level data for coloc boost
preprocess_gene_coloc_boost <- function(phenotype_id,phenotype_bed,VCF_path,covars_df){

message(phenotype_id)

message('Extracting genotype data')
genotype_data  <- expression_bed_df %>%
    extract_genotype_vector(phenotype_id,VCF_path)
genotype_matrix <- genotype_data %>% clean_genotype_data
#filtered_genotype_matrix <- genotype_matrix[ , colSums(is.na(genotype_matrix)) == 0]
filtered_genotype_matrix <- genotype_matrix[rowSums(is.na(genotype_matrix)) == 0 , ]



message('Extracting phenotype data')
phenotype_vec <- expression_bed_df %>% extract_phenotype_vector(phenotype_id)

residualized_phenotype_vec <- phenotype_vec %>%  residualize_molecular_phenotype_data(covars_df)
variant_metadata <-  extract_variant_metadata(filtered_genotype_matrix)

message('Computing LD')
LD_matrix <- get_cormat(filtered_genotype_matrix)


message('Creating output object')
output <- list(LD_matrix = LD_matrix,
               variant_metadata = variant_metadata,
               resid_phenotype_vec =residualized_phenotype_vec,
               phenotype_vec = phenotype_vec,
               genotype_matrix = genotype_matrix,
               genotype_data = genotype_data,
               name = phenotype_id)
output
}

# takes list of summary stats of runs extract_GWAS_data function to get all
# summary stats of interest
extract_GWAS_data_list <- function(preprocessed_colocboost,sumstats_list){
variant_metadata <- preprocessed_colocboost$variant_metadata
GWAS_out <- sumstats_list %>%
                map(~extract_GWAS_data(variant_metadata,.) %>% na.omit())
names(GWAS_out) <- names(sumstats_list)
GWAS_out
}


wrap_colocboost_list <- function(colocboost_preproc_object,sumstats_list){
sumstat_data <- colocboost_preproc_object %>%
    extract_GWAS_data_list(.,GWAS_summary_stats)
try(res <- colocboost(X = colocboost_preproc_object$genotype_matrix,
           Y = colocboost_preproc_object$resid_phenotype_vec,
           LD = colocboost_preproc_object$LD_matrix,
           sumstat = sumstat_data
           ))
out <- colocboost_preproc_object
out$res <- res
try(out$summary <- res %>% get_cos_summary())
out$traits <- names(sumstat_data)
out
}


proteome_transcriptome_coloc <- function(phenotype_id,
                                         transcriptome_bed,
                                         proteome_bed,
                                         transcriptome_covar,
                                         proteome_covar,
                                         VCF_path){

message(paste0('Protein/Gene running:',phenotype_id))
split_phenotype <- unlist(str_split(phenotype_id,'_'))[2]
transcriptomic_dat <- extract_phenotype_vector(transcriptome_bed,split_phenotype)
proteomic_dat <- extract_phenotype_vector(proteome_bed,phenotype_id)

if (length(transcriptomic_dat) > 0){
    
resid_transcriptomic <- transcriptomic_dat %>% residualize_molecular_phenotype_data(transcriptome_covar)
resid_proteomic <- proteomic_dat %>% residualize_molecular_phenotype_data(proteome_covar)

    
    
sample_ids <- proteome_bed %>% select(-1,-2,-3,-4) %>% colnames()
genotype_data <- proteome_bed %>%  
        extract_genotype_vector(phenotype_id,VCF_path) %>% 
        select(CHROM,POS,ID,REF,ALT,QUAL,FILTER,INFO,FORMAT,all_of(sample_ids))

genotype_matrix <- genotype_data %>% clean_genotype_data
phenotype_data <- list(outcome_1 =resid_transcriptomic,outcome_2 = resid_proteomic )

try(res <- colocboost(X = genotype_matrix[ , colSums(is.na(genotype_matrix)) == 0],
           Y = phenotype_data
           )
    )
try(res$name <- phenotype_id)
res
    }
}


