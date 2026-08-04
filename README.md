This code downloads the daily update files from PubMed, extracts the content, and builds a sqlite database.
It then deploys the database if the new size looks reasonable compared to the previous deployment.
It assumes you downloaded the baseline already. See https://pubmed.ncbi.nlm.nih.gov/download/ for info on PubMed downloads.
