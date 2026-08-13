This code downloads the daily update files from PubMed, extracts the content, and builds a sqlite database for the metadata and titles (excluding abstracts), and a separate sqlite database for abstracts.
It then deploys the databases if the new sizes look reasonable compared to the previous deployment.
It assumes you downloaded the baseline already. See https://pubmed.ncbi.nlm.nih.gov/download/ for info on PubMed downloads.

Created by Gwênlyn Glusman (Institute for Systems Biology), April 2025
