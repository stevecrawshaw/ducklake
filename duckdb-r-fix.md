The **segfault on an in-memory connection** confirms the duckdb R package installation itself is broken — not the database file. On Windows, upgrading a package with a compiled DLL while R was running can leave a corrupt install.

Fix: reinstall duckdb cleanly. Close all R/RStudio sessions first, then in a fresh R session:

```r
remove.packages("duckdb")
install.packages("duckdb")
```

If that still gives a segfault, the old DLL is locked by Windows. Do this instead:

1. Close all R sessions
2. In File Explorer, navigate to your R library (usually `C:\Users\steve.crawshaw\AppData\Local\R\win-library\4.x\`)
3. Delete the `duckdb` folder manually
4. Open a fresh R session and run `install.packages("duckdb")`

After reinstalling, verify with:
```r
library(duckdb)
con <- dbConnect(duckdb::duckdb())
dbGetQuery(con, "SELECT version()")
dbDisconnect(con)
```

Once that works cleanly, re-run `Rscript scripts/refresh.R`.
