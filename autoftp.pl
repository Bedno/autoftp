#!/usr/bin/perl
# Automated FTP utility. Andrew Bedno - andrew@bedno.com - Rev 2014.01.25
# Run standalone from command line as:  perl ./autoftp.pl batch (where "batch" selects task set)
# User defines ftp tasks to copy or move binary or ascii files singly or in sets.
# Tasks can then run run by batch on demand or scripted or scheduled.
# Not optimized for speed nor have high end features like file content/date/size comparisons nor sftp, but has worked reliably in production for many years.

# Create an array of task records, each defining a transfer from a single server and folder of one or more files.
# Task fields:
#   0: batch - Batch ID used to pick a task or set of tasks.  Recommend simple alphanum, no spaces.
#   1: direction - g=Get from remote. p=Put to remote.
#   2: server - The remote ftp server name.
#   3: login - ftp login.
#   4: password - ftp password.
#   5: mode - b=binary, a=ascii. Always overwrites. Optionally include  x  for move instead of copy, delete source file after success.
#   6: remotedir - Remote directory.
#   7: localdir - Local directory.
#   8: match - Act on all source files containing match.  Use * for all.  Use / for explicit start/end, ie: .jp matches .jpg but .jp/ matches only .jp
# Ex. @task = ( [ 'events', 'get', '','','', 'ax', '/cal/events/updated', '/dev/cal/events', '*'],
#               [ 'events', 'put', '','','', 'ax', '/cal/events', '/dev/cal/events/updated', '*'],
#               [ 'cals', 'put', '','','', 'a', '/cal', '/web/cal', '.txt/'], ... );

@task = ();

# These replace omitted task values to simplify changing globally.
$ftp_default_server = '';
$ftp_default_login = '';
$ftp_default_password = '';
$ftp_default_mode = '';

# Debug options, include any of:  s=Copy log messages to stdout.  a=Log addition diagnostic info.  x=Simulate but don't transfer.
$ftp_debug = 's';

$ftp_max_tries = 6;  # How many repeats to attempt in case of failure, each time with increased delay.
$ftp_retry_seconds = 60;  # Delay between retries, multiplied by number of attempts so far.

# If necessary, install the required module using "ppm install Net::FTP"
use Net::FTP;

@batches = ();
&GetFormInput;

# Main processing loop, loops through all batch args to execute tasks.
foreach $batch_idx (0 .. $#batches) {
  if ($batches[$batch_idx] ne "") {
    $inbatch = 0;
    foreach $task_idx (0 .. $#task) {
      if ($task[$task_idx][0] eq $batches[$batch_idx]) {
        $inbatch++;
        FTP_Log('Processing ftp batch:"'.$batches[$batch_idx].'" ...', $ftp_debug);
        if (lc(substr($task[$task_idx][1],0,1)) eq 'p') {
          &ftp_putfiles($task[$task_idx][2],$task[$task_idx][3],$task[$task_idx][4],$task[$task_idx][5],$task[$task_idx][6],$task[$task_idx][7],$task[$task_idx][8]);
        } else {
          if (lc(substr($task[$task_idx][1],0,1)) eq 'g') {
            &ftp_getfiles($task[$task_idx][2],$task[$task_idx][3],$task[$task_idx][4],$task[$task_idx][5],$task[$task_idx][6],$task[$task_idx][7],$task[$task_idx][8]);
          } else {
            FTP_Log('Bad direction argument:"'.$task[$task_idx][1].'"', $ftp_debug);
          }
        }
      }
    }
    if ($inbatch < 1) {
      FTP_Log('No tasks in batch "'.$batches[$batch_idx].'"', $ftp_debug);
    }
  }
}

FTP_Log("Done.\n\n", $ftp_debug);
exit;

# &ftp_[get|put]file[s](<server>, <login>, <password>, <mode>, <remotedir>, <localdir>, <match>);

# Put multiple files.
sub ftp_putfiles {
  $ftp_puts_server = $_[0];
  $ftp_puts_login = $_[1];
  $ftp_puts_password = $_[2];
  $ftp_puts_mode = $_[3];
  $ftp_puts_remotedir = $_[4];
  $ftp_puts_localdir = $_[5];
  $ftp_puts_match = $_[6];
  $ftp_puts_error = &CheckArgs('Put files', $ftp_puts_server,$ftp_puts_login,$ftp_puts_password,$ftp_puts_mode,$ftp_puts_remotedir,$ftp_puts_localdir,$ftp_puts_match);
  if ($ftp_puts_error eq "") {
    if ($ftp_puts_server eq "") { $ftp_puts_server = $ftp_default_server; }
    if ($ftp_puts_login eq "") { $ftp_puts_login = $ftp_default_login; }
    if ($ftp_puts_password eq "") { $ftp_puts_password = $ftp_default_password; }
    if ($ftp_puts_mode eq "") { $ftp_puts_mode = $ftp_default_mode; }
  }
  $ftp_puts_debug = 'PUT: Match:"'.$ftp_puts_match.'" LocalDir:"'.$ftp_puts_localdir.'" RemoteDir:"'.$ftp_puts_remotedir.'" Mode:"'.$ftp_puts_mode.'" System:"'.$ftp_puts_server.'"';
  if ($ftp_debug =~ /a/) {
    FTP_Log($ftp_puts_debug.' Login:"'.$ftp_puts_login.'" Password:"'.$ftp_puts_password.'"', $ftp_debug);
  }
  if ($ftp_puts_error eq "") {
    if (! -d $ftp_puts_localdir) {
      $ftp_puts_error = 'Put files: Local dir "'.$ftp_puts_localdir.'" not found.';
    }
  }
  if ($ftp_puts_error eq "") {
    opendir(LSIN, $ftp_puts_localdir);
    @raw_files_ls = readdir(LSIN);
    closedir (LSIN);
    foreach $curr_file (sort {uc($a) cmp uc($b)} @raw_files_ls) {
      $full_file = $ftp_puts_localdir."/".$curr_file;
      if (-f $full_file) {
        $curr_file_match = '/'.$curr_file.'/';
        if ( ($curr_file_match =~ /$ftp_puts_match/i) or  ($ftp_puts_match eq '*') ) {
          &ftp_putfile($ftp_puts_server,$ftp_puts_login,$ftp_puts_password,$ftp_puts_mode,$ftp_puts_remotedir,$ftp_puts_localdir,$curr_file);
        }
      }
    }
  }
  if ($ftp_puts_error ne "") {
    FTP_Log($ftp_puts_debug.', '.$ftp_puts_error, $ftp_debug);
  }
}

# Put file with retries.
sub ftp_putfile {
  $ftp_put_server = $_[0];
  $ftp_put_login = $_[1];
  $ftp_put_password = $_[2];
  $ftp_put_mode = $_[3];
  $ftp_put_remotedir = $_[4];
  $ftp_put_localdir = $_[5];
  $ftp_put_file = $_[6];
  $ftp_put_retries = 0;
  $ftp_put_result = "Starting.";
  $ftp_put_error = &CheckArgs('Put file', $ftp_put_server,$ftp_put_login,$ftp_put_password,$ftp_put_mode,$ftp_put_remotedir,$ftp_put_localdir,$ftp_put_file);
  if ($ftp_put_error eq "") {
    if ($ftp_put_server eq "") { $ftp_put_server = $ftp_default_server; }
    if ($ftp_put_login eq "") { $ftp_put_login = $ftp_default_login; }
    if ($ftp_put_password eq "") { $ftp_put_password = $ftp_default_password; }
    if ($ftp_put_mode eq "") { $ftp_put_mode = $ftp_default_mode; }
  }
  if (! -f $ftp_put_localdir.'/'.$ftp_put_file) {
    $ftp_put_msg = 'Put file: Source file not found:"'.$ftp_put_localdir.'/'.$ftp_put_file.'".';
    FTP_Log($ftp_put_msg, $ftp_debug.'s');
  } else {
    while ( ($ftp_put_retries < $ftp_max_tries) and ($ftp_put_result ne "") ) {
      $ftp_put_result = ftp_upfile($ftp_put_server,$ftp_put_login,$ftp_put_password,$ftp_put_mode,$ftp_put_remotedir,$ftp_put_localdir,$ftp_put_file);
      if ($ftp_put_result ne "") {
        $ftp_put_retries++;
        $ftp_put_msg = "Attempt # ".$ftp_put_retries.", ".$ftp_put_result;
        FTP_Log($ftp_put_msg, $ftp_debug);
        if ($ftp_put_retries < $ftp_max_tries) { sleep($ftp_retry_seconds*$ftp_put_retries); }
      }
    }
    if ($ftp_put_result eq "") {
      $ftp_put_msg = 'Put "'.$ftp_put_localdir.'/'.$ftp_put_file.'" to "'.$ftp_put_server.':'.$ftp_put_remotedir.'" OK.';
      FTP_Log($ftp_put_msg, $ftp_debug);
    } else {
      $ftp_put_msg = 'PUT FAILED "'.$ftp_put_localdir.'/'.$ftp_put_file.'" to "'.$ftp_put_server.':'.$ftp_put_remotedir.'"';
      FTP_Log($ftp_put_msg, $ftp_debug.'s');
    }
  }
  return();
}

# Upload a file by ftp, bottom layer.
sub ftp_upfile {
  $ftp_up_server = $_[0];
  $ftp_up_login = $_[1];
  $ftp_up_password = $_[2];
  $ftp_up_mode = $_[3];
  $ftp_up_remotedir = $_[4];
  $ftp_up_localdir = $_[5];
  $ftp_up_file = $_[6];
  # Sanity checks.
  $ftp_up_error = &CheckArgs('Upload', $ftp_up_server,$ftp_up_login,$ftp_up_password,$ftp_up_mode,$ftp_up_remotedir,$ftp_up_localdir,$ftp_up_file);
  if ($ftp_up_error eq "") {
    if ($ftp_up_server eq "") { $ftp_up_server = $ftp_default_server; }
    if ($ftp_up_login eq "") { $ftp_up_login = $ftp_default_login; }
    if ($ftp_up_password eq "") { $ftp_up_password = $ftp_default_password; }
    if ($ftp_up_mode eq "") { $ftp_up_mode = $ftp_default_mode; }
  }
  $ftp_up_debug = 'Put:"'.$ftp_up_localdir.'/'.$ftp_up_file.'" RemoteDir:"'.$ftp_up_remotedir.'" Mode:"'.$ftp_up_mode.'" System:"'.$ftp_up_server.'"';
  if ($ftp_debug =~ /a/) {
    FTP_Log($ftp_up_debug.' Login:"'.$ftp_up_login.'" Password:"'.$ftp_up_password.'"', $ftp_debug);
  }
  if ($ftp_up_error eq "") {
    if (! -f $ftp_up_localdir.'/'.$ftp_up_file) {
      $ftp_up_error = "Upload: Source file not found.\n";
    }
  }
  # Create the FTP object
  if ($ftp_debug !~ /x/) {
    if ($ftp_up_error eq "") {
      $ftp = Net::FTP->new($ftp_up_server);
      if (!defined($ftp)) {
        $ftp_up_error = 'Upload: Cannot create FTP object:"'.$@.'"';
      } else {
        # Log into the remote host
        if ($ftp_up_error eq "") {
          if ($ftp->login($ftp_up_login, $ftp_up_password) == 0) {
            $ftp_up_error = "Upload: Cannot login to server.";
          }
        }
        # Change to the specified directory
        if ($ftp_up_error eq "") {
          if ($ftp->cwd($ftp_up_remotedir) == 0) {
            $ftp_up_error = "Upload: Cannot change remote directory.";
          }
        }
        # Set file mode.
        if ($ftp_up_error eq "") {
          $ftp_up_status = ($ftp_up_mode =~ /a/i) ? $ftp->ascii : $ftp->binary;
          if (!defined($ftp_up_status)) {
            $ftp_up_error = "Upload: Cannot set file mode.";
          }
        }
        # Upload file.
        if ($ftp_up_error eq "") {
          $ftp_up_status = $ftp->put($ftp_up_localdir.'/'.$ftp_up_file);
          if (!defined($ftp_up_status)) {
            $ftp_up_error = "Upload: Cannot upload file.";
          }
        }
        # Close.
        if ($ftp_up_error eq "") {
          sleep(3);
          $ftp_up_status = $ftp->quit;
          if ($ftp_up_status != 1) {
            $ftp_up_error = "Upload: Cannot quit.";
          }
        }
        if ( ($ftp_up_error ne "") and ($ftp->message ne "") ) {
          $ftp_up_error .= ', Error message "'.$ftp->message.'"';
        }
      }
    }
    if ($ftp_up_error ne "") {
      $ftp_up_error = $ftp_up_debug.', '.$ftp_up_error;
    }
    if ($ftp_up_error eq "") {
      if ($ftp_up_mode =~ /x/i) {
        unlink ($ftp_up_localdir.'/'.$ftp_up_file);
      }
    }
  }
  return $ftp_up_error;
}

# Get multiple files.
sub ftp_getfiles {
  $ftp_gets_server = $_[0];
  $ftp_gets_login = $_[1];
  $ftp_gets_password = $_[2];
  $ftp_gets_mode = $_[3];
  $ftp_gets_remotedir = $_[4];
  $ftp_gets_localdir = $_[5];
  $ftp_gets_match = $_[6];
  $ftp_gets_error = &CheckArgs('Get files', $ftp_gets_server,$ftp_gets_login,$ftp_gets_password,$ftp_gets_mode,$ftp_gets_remotedir,$ftp_gets_localdir,$ftp_gets_match);
  if ($ftp_gets_error eq "") {
    if ($ftp_gets_server eq "") { $ftp_gets_server = $ftp_default_server; }
    if ($ftp_gets_login eq "") { $ftp_gets_login = $ftp_default_login; }
    if ($ftp_gets_password eq "") { $ftp_gets_password = $ftp_default_password; }
    if ($ftp_gets_mode eq "") { $ftp_gets_mode = $ftp_default_mode; }
  }
  $ftp_gets_debug = 'GET: Match:"'.$ftp_gets_match.'" LocalDir:"'.$ftp_gets_localdir.'" RemoteDir:"'.$ftp_gets_remotedir.'" Mode:"'.$ftp_gets_mode.'" System:"'.$ftp_gets_server.'"';
  if ($ftp_debug =~ /a/) {
    FTP_Log($ftp_gets_debug.' Login:"'.$ftp_gets_login.'" Password:"'.$ftp_gets_password.'"', $ftp_debug);
  }
  if ($ftp_debug !~ /x/) {
    if ($ftp_gets_error eq "") {
      $ftp = Net::FTP->new($ftp_gets_server);
      if (!defined($ftp)) {
        $ftp_gets_error = 'Get files: Cannot create FTP object:"'.$@.'"';
      } else {
        # Log into the remote host
        if ($ftp_gets_error eq "") {
          if ($ftp->login($ftp_gets_login, $ftp_gets_password) == 0) {
            $ftp_gets_error = "Get files: Cannot login to server.";
          }
        }
        # Change to the specified directory
        if ($ftp_gets_error eq "") {
          if ($ftp->cwd($ftp_gets_remotedir) == 0) {
            $ftp_gets_error = "Get files: Cannot change remote directory.";
          }
        }
        if ($ftp_gets_error eq "") {
          if (@remote_ls = $ftp->ls()) {
            if (@remote_ls == 0) {
              $ftp_gets_error = "Get files: Cannot list remote directory.";
            }
          }
        }
      }
      if ( ($ftp_gets_error ne "") and (defined($ftp->message)) and ($ftp->message ne "") ) {
        $ftp_gets_error .= ', Error message "'.$ftp->message.'"';
      }
    }
    if ($ftp_gets_error eq "") {
      if (! -d $ftp_gets_localdir) {
        $ftp_gets_error = 'Get files: Local dir "'.$ftp_gets_localdir.'" not found.';
      }
    }
    if ($ftp_gets_error eq "") {
      foreach $curr_file (sort {uc($a) cmp uc($b)} @remote_ls) {
        $curr_file_match = '/'.$curr_file.'/';
        if ( ($curr_file_match =~ /$ftp_gets_match/i) or
			 ( ($curr_file ne '.') and ($curr_file ne '..') and ($ftp_gets_match eq '*') ) ) {
          &ftp_getfile($ftp_gets_server,$ftp_gets_login,$ftp_gets_password,$ftp_gets_mode,$ftp_gets_remotedir,$ftp_gets_localdir,$curr_file);
        }
      }
    }
  }
  if ($ftp_gets_error ne "") {
    FTP_Log($ftp_gets_debug.', '.$ftp_gets_error, $ftp_debug.'s');
  }
}

# Get file with retries.
sub ftp_getfile {
  $ftp_get_server = $_[0];
  $ftp_get_login = $_[1];
  $ftp_get_password = $_[2];
  $ftp_get_mode = $_[3];
  $ftp_get_remotedir = $_[4];
  $ftp_get_localdir = $_[5];
  $ftp_get_file = $_[6];
  $ftp_get_error = &CheckArgs('Get file', $ftp_get_server,$ftp_get_login,$ftp_get_password,$ftp_get_mode,$ftp_get_remotedir,$ftp_get_localdir,$ftp_get_file);
  if ($ftp_get_error eq "") {
    if ($ftp_get_server eq "") { $ftp_get_server = $ftp_default_server; }
    if ($ftp_get_login eq "") { $ftp_get_login = $ftp_default_login; }
    if ($ftp_get_password eq "") { $ftp_get_password = $ftp_default_password; }
    if ($ftp_get_mode eq "") { $ftp_get_mode = $ftp_default_mode; }
  }
  $ftp_get_retries = 0;
  $ftp_get_result = "Starting.";
  if ($ftp_get_error eq "") {
    while ( ($ftp_get_retries < $ftp_max_tries) and ($ftp_get_result ne "") ) {
      $ftp_get_result = ftp_downfile($ftp_get_server,$ftp_get_login,$ftp_get_password,$ftp_get_mode,$ftp_get_remotedir,$ftp_get_localdir,$ftp_get_file);
      if ($ftp_get_result ne "") {
        $ftp_get_retries++;
        $ftp_get_msg = "Attempt # ".$ftp_get_retries.", ".$ftp_get_result;
        FTP_Log($ftp_get_msg, $ftp_debug);
        if ($ftp_get_retries < $ftp_max_tries) { sleep($ftp_retry_seconds*$ftp_get_retries); }
      }
    }
    if (! -f $ftp_get_localdir.'/'.$ftp_get_file) {
      $ftp_get_msg = 'GET FAILED - Downloaded file missing:"'.$ftp_get_localdir.'/'.$ftp_get_file.'".';
      FTP_Log($ftp_get_msg, $ftp_debug.'s');
    } else {
      if ($ftp_get_result eq "") {
        $ftp_get_msg = 'Get "'.$ftp_get_localdir.'/'.$ftp_get_file.'" from "'.$ftp_get_server.':'.$ftp_get_remotedir.'" OK.';
        FTP_Log($ftp_get_msg, $ftp_debug);
      } else {
        $ftp_get_msg = 'GET FAILED "'.$ftp_get_localdir.'/'.$ftp_get_file.'" from "'.$ftp_get_server.':'.$ftp_get_remotedir.'"';
        FTP_Log($ftp_get_msg, $ftp_debug.'s');
      }
    }
  }
  return();
}

# Download a file by ftp, bottom layer.
sub ftp_downfile {
  $ftp_down_server = $_[0];
  $ftp_down_login = $_[1];
  $ftp_down_password = $_[2];
  $ftp_down_mode = $_[3];
  $ftp_down_remotedir = $_[4];
  $ftp_down_localdir = $_[5];
  $ftp_down_file = $_[6];
  # Sanity checks.
  $ftp_down_error = &CheckArgs('Download', $ftp_down_server,$ftp_down_login,$ftp_down_password,$ftp_down_mode,$ftp_down_remotedir,$ftp_down_localdir,$ftp_down_file);
  if ($ftp_down_error eq "") {
    if ($ftp_down_server eq "") { $ftp_down_server = $ftp_default_server; }
    if ($ftp_down_login eq "") { $ftp_down_login = $ftp_default_login; }
    if ($ftp_down_password eq "") { $ftp_down_password = $ftp_default_password; }
    if ($ftp_down_mode eq "") { $ftp_down_mode = $ftp_default_mode; }
  }
  $ftp_down_debug = 'Get:"'.$ftp_down_file.'" LocalDir:"'.$ftp_down_localdir.'" RemoteDir:"'.$ftp_down_remotedir.'" Mode:"'.$ftp_down_mode.'" System:"'.$ftp_down_server.'"';
  # Create the FTP object
  if ($ftp_debug =~ /a/) {
    FTP_Log($ftp_down_debug.' Login:"'.$ftp_down_login.'" Password:"'.$ftp_down_password.'"', $ftp_debug);
  }
  if ($ftp_debug !~ /x/) {
    if ($ftp_down_error eq "") {
      if (! -d $ftp_down_localdir) {
        $ftp_down_error = 'Download: Local dir "'.$ftp_down_localdir.'" not found.';
      }
    }
    if ($ftp_down_error eq "") {
      $ftp = Net::FTP->new($ftp_down_server);
      if (!defined($ftp)) {
        $ftp_down_error = 'Download: Cannot create FTP object:"'.$@.'"';
      } else {
        # Log into the remote host
        if ($ftp_down_error eq "") {
          if ($ftp->login($ftp_down_login, $ftp_down_password) == 0) {
            $ftp_down_error = "Download: Cannot login to server.";
          }
        }
        # Change to the specified directory
        if ($ftp_down_error eq "") {
          if ($ftp->cwd($ftp_down_remotedir) == 0) {
            $ftp_down_error = "Download: Cannot change remote directory.";
          }
        }
        # Set file mode.
        if ($ftp_down_error eq "") {
          $ftp_down_status = ($ftp_down_mode =~ /a/i) ? $ftp->ascii : $ftp->binary;
          if (!defined($ftp_down_status)) {
            $ftp_down_error = "Download: Cannot set file mode.";
          }
        }
        # Download file.
        if ($ftp_down_error eq "") {
          $ftp_down_status = $ftp->get($ftp_down_file, $ftp_down_localdir.'/'.$ftp_down_file);
          if (!defined($ftp_down_status)) {
            $ftp_down_error = "Download: Cannot download file.";
          }
        }
        if ($ftp_down_error eq "") {
          if ($ftp_down_mode =~ /x/i) {
            $ftp_down_status = $ftp->delete($ftp_down_file);
            if (! $ftp_down_status) {
              $ftp_down_error = "Download: Cannot remove file.";
            }
          }
        }
        # Close.
        if ($ftp_down_error eq "") {
          sleep(3);
          $ftp_down_status = $ftp->quit;
          if ($ftp_down_status != 1) {
            $ftp_down_error = "Download: Cannot quit.";
          }
        }
        if ( ($ftp_down_error ne "") and ($ftp->message ne "") ) {
          $ftp_down_error .= ', Error message "'.$ftp->message.'"';
        }
      }
    }
    if ($ftp_down_error ne "") {
      $ftp_down_error = $ftp_down_debug.', '.$ftp_down_error;
    }
  }
  return $ftp_down_error;
}

# Sanity check all arguments.
sub CheckArgs {
  $ftp_check_type = $_[0];
  $ftp_check_server = $_[1];
  $ftp_check_login = $_[2];
  $ftp_check_password = $_[3];
  $ftp_check_mode = $_[4];
  $ftp_check_remotedir = $_[5];
  $ftp_check_localdir = $_[6];
  $ftp_check_file = $_[7];
  $ftp_check_error = "";
  if ($ftp_check_server eq "") { $ftp_check_server = $ftp_default_server; }
  if ($ftp_check_login eq "") { $ftp_check_login = $ftp_default_login; }
  if ($ftp_check_password eq "") { $ftp_check_password = $ftp_default_password; }
  if ($ftp_check_mode eq "") { $ftp_check_mode = $ftp_default_mode; }
  if ($ftp_check_error eq "") { if ($ftp_check_server eq "") { $ftp_check_error = $ftp_check_type.": No server specified."; } }
  if ($ftp_check_error eq "") { if ($ftp_check_login eq "") { $ftp_check_error = $ftp_check_type.": No login specified."; } }
  if ($ftp_check_error eq "") { if ($ftp_check_password eq "") { $ftp_check_error = $ftp_check_type.": No password specified."; } }
  if ($ftp_check_error eq "") { if ($ftp_check_mode eq "") { $ftp_check_error = $ftp_check_type.": No mode specified."; } }
  if ($ftp_check_error eq "") { if ($ftp_check_remotedir eq "") { $ftp_check_error = $ftp_check_type.": No remote dir specified."; } }
  if ($ftp_check_error eq "") { if ($ftp_check_localdir eq "") { $ftp_check_error = $ftp_check_type.": No local dir specified."; } }
  if ($ftp_check_error eq "") { if ($ftp_check_file eq "") { $ftp_check_error = $ftp_check_type.": No file match specified."; } }
  if ($ftp_check_error eq "") { if ( ($ftp_check_file =~ /[\?\*\[\]\&\^\$]/) and ($ftp_check_file ne '*') ) { $ftp_check_error = $ftp_check_type.": Wildcards not supported in file match target."; } }
  if ($ftp_check_error eq "") {
    if (($ftp_check_mode !~ /a/i) and ($ftp_check_mode !~ /b/i) and ($ftp_check_mode ne "")) {
      $ftp_check_error = $ftp_check_type.': Invalid mode "'.$ftp_check_mode.'"'."";
    }
  }
  return $ftp_check_error;
}


sub FTP_Log {
  $log_in = $_[0];
  $log_level = $_[1];
  $log_in =~ s/[\r\n\f\t]+/ /g;
  ($LogSec, $LogMin, $LogHr, $LogDa, $LogMo, $LogYr) = localtime();
  $LogMo++;  $LogYr += 1900;
  $LogYYYYMMDDHHMMSS = sprintf("%04d.%02d.%02d %02d:%02d:%02d", $LogYr, $LogMo, $LogDa, $LogHr, $LogMin, $LogSec);
  open (TRACK_LOG, ">> autoftp.log");
  print TRACK_LOG $LogYYYYMMDDHHMMSS." ".$log_in."\n";
  close (TRACK_LOG);
  chmod(0666, "autoftp.log");
  if ($log_level =~ /s/) {
    syswrite STDOUT, $log_in."\r\n";
  }
}

sub GetFormInput {
  local ($buf);
  # Fetch all get or post form values or command line args.
  $buf = '';
  (*fval) = @_ if @_;
  if ( (! $local_mode) || (@ARGV < 1) ) {
    if ($ENV{'REQUEST_METHOD'} eq 'POST') {
      read(STDIN,$buf,$ENV{'CONTENT_LENGTH'});
    } else {
      $buf=$ENV{'QUERY_STRING'};
    }
  }
  if ($buf !~ /[a-zA-Z0-9]/) {
    for ($arg_lp = 0; $arg_lp < @ARGV; $arg_lp++) { $buf .= '&'.$ARGV[$arg_lp]; }
    if (! $buf) { $buf = $ARGV[0]; }
  }
  if ($buf eq "") {
    return 0;
  } else {
    @batches=split(/&/,$buf);
  }
  return 1;
}

