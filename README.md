autoftp
=======

Automated FTP utility in Perl.

Utility for automating routine FTP tasks such as copy or move of single or multiple files.

Run standalone from command line as:  perl ./autoftp.pl batch (where "batch" selects task set)

User first defines ftp tasks to copy or move binary or ascii files singly or in sets.
Tasks can then run run by batch on demand or scripted or scheduled.

Not optimized for speed nor have high end features like file content/date/size comparisons nor sftp, but has worked reliably in production for many years.
