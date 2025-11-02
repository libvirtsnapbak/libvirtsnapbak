#!/usr/bin/env bash
#
# Copyright (C) 2025 Jeff Pollard - libvirtsnapbak@outlook.com
#
# This file is part of LibvirtSnapBak, licensed under the GNU AGPLv3.
#
# This program is free software: you can redistribute it and/or modify 
# it under the terms of the GNU Affero General Public License as 
# published by the Free Software Foundation, either version 3 of 
# the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, 
# but WITHOUT ANY WARRANTY; without even the implied warranty of 
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
# You should have received a copy of the GNU General Public License
# along with LibvirtSnapBak.  If not, see <http://www.gnu.org/licenses/>.
#
# LibvirtSnapBak is a divergent fork of fi-backup by Davide Guerri.
#

# Set fail options
set -o pipefail

# Set Global Constants
_APP_VERSION="1.0.0"
_APP_NAME="LibvirtSnapBak"
_QEMU_IMG="/usr/bin/qemu-img"
_VIRSH="/usr/bin/virsh"
_QEMU="/usr/bin/qemu-system-x86_64"
_RSYNC="/usr/bin/rsync"
_QEMU_SYSTEM="qemu:///system"
_LOCK_DIR="/var/lock"

# Set Global Defaults
_ARR_DOMAIN=()
_ARR_EXCLUSION=()
_ARR_BLOCK_DEVICE=()
_ARR_FILE=()
_ARR_FILE_FORMAT=()
_ARR_FILE_SOURCE_PATH=()
_ARR_FILE_BACKUP_PATH=()
_ARR_FILE_FLAG_IS_BLOCK_DEVICE=()
_ARR_FILE_FLAG_HAS_BACKING_FILE=()
_ARR_FILE_BACKING_FILE=()
_ARR_FILE_BACKING_PATH=()
_ARR_FILE_BACKING_FORMAT=()
_ARR_SNAPSHOT=()
_SELECTED_OPTIONS=""
_BACKUP_DIR=""
_BACKUP_MODE=""
_FLAG_ALL_DOMAINS=0
_FLAG_ALL_NON_RUNNING=0
_MAX_DIFFS=0
_FLAG_VERBOSE=0
_FLAG_DEBUG=0
_LOG_FILE=""
_FLAG_COPY_SWITCH=0
_FLAG_CONSOLIDATE_SWITCH=0
_FLAG_ARCHIVE_SWITCH=0
_FLAG_STOP_SWITCH=0
_FLAG_ERROR=0
_LOCK_FD=0
_DIFF_TIMESTAMP="$(date "+%Y%m%d-%H%M%S")"
_THIS_BACKING_FILE=""
_FLAG_DOMAIN_HAS_TEMP=0
_FLAG_DOMAIN_HAS_BITMAP=0
_FLAG_DOMAIN_HAS_SNAPSHOT=0
_FLAG_DOMAIN_HAS_MANUAL=0
_FLAG_DOMAIN_HAS_DIFF=0
_FLAG_DOMAIN_HAS_REVERTED=0
_PREV_DIFF_TIMESTAMP="$(date "+%Y%m%d-%H%M%S")"
_FLAG_THIS_DOMAIN_RUNNING=0

function print_usage() {
   # Print usage
   cat <<EOU

   $_APP_NAME version $_APP_VERSION
   Copyright (C) 2025 by Jeff Pollard
   This program is licensed under the GNU AGPLv3.

   Usage:
   sudo $0 [OPTIONS]

   Options:
   --help, -h                    Print usage and exit
   --version, -v                 Print version and exit
   --backup-dir, -b=<dir>        Backup to the specified <dir> [Required]
   --mode, -m=<mode>             Backup in specified <mode> [Required]
                                 <diff>:
                                 - Backup current differential snapshot (start new if none)
                                 - Retain previous differential snapshot(s) in 'DiffHistory' dir
                                 <copy>:
                                 - Backup current differential snapshot & base file(s) in 'Copy' dir
                                 - Rebase all linkages (full standalone backup)
                                 <consolidate>:
                                 - Consolidate current differential snapshot into base
                                 - Backup base file(s)
                                 - Start new differential snapshot
                                 <archive>:
                                 - Consolidate current differential snapshot into base
                                 - Backup base file(s) in 'Archive' dir
                                 - Rebase all linkages (full standalone backup)
                                 - Stop differential
                                 <stop>:
                                 - Consolidate existing differential snapshot into base
                                 - Stop differential
   --all, -a                     Backup all domains [Overrides --non-running, --domain]
   --non-running, -n             Backup all non-running domains [Overrides --domain]
   --domain, -d=<domain name>    Backup specified <domain name> [Required unless --all or --non-running]
   --exclude, -e=<domain name>   Exclude specified <domain name>
   --prune, -p=<max number>      Prune 'DiffHistory' dir:
                                 - Retain <max number> most recent differential snapshots
   --debug, -D                   Debug
   --verbose, -V                 Verbose

   Version Requirements:
      bash     >= 4.3.0
      qemu_img >= 1.2.0
      qemu     >= 1.2.0
      rsync    >= 2.6.0
      virsh    >= 0.9.13

EOU
   return 0
}

function print_version() {
   echo "$_APP_VERSION"
   return 0
}

function parse_options() {
   # Try to parse selected options and check validity, otherwise return error
   local _ret
   local _timeStamp
   local _cmd
   local _outputFlat
   local _inputParsed

   _ret=0
   _timeStamp="$(date "+%Y%m%d-%H%M%S")"
   _SELECTED_OPTIONS="$*"

   echo "$_timeStamp [INF] Selected options: [$_SELECTED_OPTIONS]"

   _cmd=$(getopt -o hvb:m:d:ane:p:DV --long help,version,backup-dir:,mode:,domain:,all,non-running,exclude:,prune:,verbose,debug -- "$@" 2>&1)
   _ret=$?

   if (( _ret != 0 )); then
      _outputFlat="$(echo "$_cmd" | tr '\n' ' ')"
      echo "$_timeStamp [ERR] Error parsing options: output=[$_outputFlat]"
      return $_ret
   fi

   eval set -- "$_cmd"

   while true; do
      case "$1" in
         -h|--help)
            print_usage
            exit $_ret ;;
         -v|--version)
            print_version
            exit $_ret ;;
         -b|--backup-dir)
            if [[ -n "$2" && "$2" != -* ]]; then
               _inputParsed="${2#=}" # remove leading equals
               _inputParsed="${_inputParsed%/}" # remove trailing '/' (if any)
               _BACKUP_DIR="$_inputParsed"
            else
               _ret=1
               echo "$_timeStamp [ERR] Valid backup directory [-b=<dir>] is required"
               break
            fi
            shift 2 ;;
         -m|--mode)
            if [[ -n "$2" && "$2" != -* ]]; then
               _inputParsed="${2#=}" # remove leading equals
               _BACKUP_MODE="$_inputParsed"
            else
               _ret=1
               echo "$_timeStamp [ERR] Valid backup mode is required [-m=diff|copy|consolidate|archive|stop]"
               break
            fi
            shift 2 ;;
         -a|--all)
            _FLAG_ALL_DOMAINS=1
            shift ;;
         -n|--non-running)
            if (( _FLAG_ALL_DOMAINS == 0 )); then
               _FLAG_ALL_NON_RUNNING=1
            fi
            shift ;;
         -d|--domain)
            if (( _FLAG_ALL_DOMAINS == 0 )) && (( _FLAG_ALL_NON_RUNNING == 0 )); then
               if [[ -n "$2" && "$2" != -* ]]; then
                  _inputParsed="${2#=}" # remove leading equals
                  _ARR_DOMAIN+=("$_inputParsed")
               else
                  _ret=1
                  echo "$_timeStamp [ERR] Domain name [-d=<domain name>] is required"
                  break
               fi
            fi
            shift 2 ;;
         -e|--exclude)
            if [[ -n "$2" && "$2" != -* ]]; then
               _inputParsed="${2#=}" # remove leading equals
               _ARR_EXCLUSION+=("$_inputParsed")
            else
               _ret=1
               echo "$_timeStamp [ERR] Please enter a valid [-e=<domain name>]"
               break
            fi
            shift 2 ;;
         -p|--prune)
            if [[ -n "$2" && "$2" != -* ]]; then
               _inputParsed="${2#=}" # remove leading equals
               _MAX_DIFFS="$_inputParsed"
            else
               _ret=1
               echo "$_timeStamp [ERR] Please specify [-p=<max number>] greater than 0"
               break
            fi
            shift 2 ;;
         -V|--verbose)
            _FLAG_VERBOSE=1
            shift ;;
         -D|--debug)
            _FLAG_VERBOSE=1
            _FLAG_DEBUG=1
            shift ;;
         -- )
            shift
            break ;;
         *)
            _ret=1
            echo "$_timeStamp [ERR] Invalid option: $1"
            break ;;
      esac
   done

   if (( _ret == 0 )) && [[ $# -gt 0 ]]; then
      _ret=1
      echo "$_timeStamp [ERR] Invalid option: $1"
   fi

   if (( _ret != 0 )); then
      print_usage
   fi

   return $_ret
}

function validate_options() {
   # Check selected options are valid, otherwise return error
   local _ret
   local _timeStamp

   _ret=0
   _timeStamp="$(date "+%Y%m%d-%H%M%S")"

   if [[ -z "$_BACKUP_DIR" ]]; then
      _ret=1
      echo "$_timeStamp [ERR] Valid backup directory [-b=<directory>] is required"
   fi

   if [[ ! -d "$_BACKUP_DIR" ]]; then
      _ret=1
      echo "$_timeStamp [ERR] Backup directory [-b=$_BACKUP_DIR] does not exist"
   fi

   case "$_BACKUP_MODE" in
      diff|copy|consolidate|archive|stop) 
         ;;
      *) 
         _ret=1
         echo "$_timeStamp [ERR] Valid backup mode is required [-m=diff|copy|consolidate|archive|stop]"
         ;;
   esac

   if (( _FLAG_ALL_DOMAINS != 0 )); then
      _FLAG_ALL_NON_RUNNING=0
      _ARR_DOMAIN=()
   fi

   if (( _FLAG_ALL_DOMAINS == 0 )) && (( _FLAG_ALL_NON_RUNNING != 0 )); then
      _ARR_DOMAIN=()
   fi

   if (( _FLAG_ALL_DOMAINS == 0 )) && (( _FLAG_ALL_NON_RUNNING == 0 )) && (( ${#_ARR_DOMAIN[@]} == 0 )); then
      _ret=1
      echo "$_timeStamp [ERR] Domain name [-d=<domain name>] is required"
   fi

   if [[ -z "$_MAX_DIFFS" ]]; then
      if [[ "$_MAX_DIFFS" =~ ^[0-9]+$ ]]; then
         if (( _MAX_DIFFS <= 0 )); then
            _ret=1
            echo "$_timeStamp [ERR] Please specify a [-p=<max number>] greater than 0"
         fi
      else
         _ret=1
         echo "$_timeStamp [ERR] Please specify a [-p=<max number>] greater than 0"
      fi
   fi

   if (( _ret != 0 )); then
      print_usage
   fi

   return $_ret
}

function check_permissions_on_backup_dir() {
# Check permissions on backup dir, otherwise return error
   local _ret
   local _timeStamp

   _ret=0
   _timeStamp="$(date "+%Y%m%d-%H%M%S")"

   if [ ! -r "$_BACKUP_DIR" ] || [ ! -w "$_BACKUP_DIR" ] || [ ! -x "$_BACKUP_DIR" ]; then
      _ret=1
      echo "$_timeStamp [ERR] read, write, and execute permissions required on specified backup directory [$_BACKUP_DIR]"
   fi

   return $_ret
}

function set_log_dir() {
   local _logDir
   local _timeStamp

   _logDir="$_BACKUP_DIR/_logs"
   if [[ ! -d "$_logDir" ]]; then
      mkdir "$_logDir"
   fi
   _timeStamp="$(date "+%Y%m%d-%H%M%S")"
   _LOG_FILE="$_logDir/LibvirtSnapBak-$_timeStamp.log"

   return 0
}

function log_message() {
   # Generate log message at selected logging level
   local _timeStamp
   local _level
   local _logLevel
   local _msg
   local _logEntry

   _timeStamp="$(date "+%Y%m%d-%H%M%S")"
   _level="$1"
   case "$_level" in
      v) _logLevel="[VER]";;
      d) _logLevel="[DEB]";;
      e) _logLevel="[ERR]";;
      w) _logLevel="[WRN]";;
      *) _logLevel="[INF]";;
   esac
   shift
   _msg="$*"

   _logEntry="$_timeStamp $_logLevel $_msg"

   # Echo log entry to log file
   echo -e "$_logEntry" >> "$_LOG_FILE"

   # Echo log entry on screen
   case "$_level" in
      v) [ "$_FLAG_VERBOSE" -eq 1 ] && echo -e "$_logEntry";;
      d) [ "$_FLAG_DEBUG" -eq 1 ] && echo -e "$_logEntry";;
      e|w|*) echo -e "$_logEntry";;
   esac

   return 0
}

function libvirt_version() {
   # Get installed libirt version
   "$_VIRSH" -v
}

function qemu_version() {
   # Get installed qemu-system version
   "$_QEMU" --version | awk '/^QEMU emulator version / { print $4 }'
}

function qemu_img_version() {
   # Get installed qemu-img version
   "$_QEMU_IMG" -h | awk '/qemu-img version / { print $3 }' | cut -d',' -f1
}

function rsync_version() {
   # Get installed libirt version
   "$_RSYNC" --version | awk 'NR==1 {print $3}'
}

function check_version() {
   # Check if dependency version is greater than or equal to supported version, otherwise return error
   local _ret
   local _version
   local _check
   local _winner

   _ret=0
   _version="$1"
   _check="$2"

   _winner="$(echo -e "$_version\n$_check" | sed '/^$/d' | sort -Vr | head -1)"

   # if version is the winner (version vs check), or version = check
   if [[ "$_version" = "$_winner" ]] || [[ "$_version" = "$_check" ]]; then
      _ret=0  # supported
   else
      _ret=1  # not supported
   fi

   return $_ret
}

function check_dependencies() {
   # Check whether virsh, qemu-img, qemu, and bash are executable and versions are supported, otherwise return error
   local _ret
   local _msg
   local _version

   _ret=0

   _version="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}"
   if check_version "$_version" '4.3.0'; then
      _msg="Dependency: bash version [$_version] is supported"
      log_message d "$_msg"
   else
      _ret=1
      _msg="Dependency: bash version [$_version] is not suppoorted - 4.3.0 or later is required"
      log_message e "$_msg"
   fi

   if [[ ! -x "$_QEMU_IMG" ]]; then
      _ret=1
      _msg="Dependency: qemu_img cannot be found or executed in specified location [$_QEMU_IMG]"
      log_message e "$_msg"
   fi

   if [[ ! -x "$_QEMU" ]]; then
      _ret=1
      _msg="Dependency: qemu-system-x86_64 cannot be found or executed in specified location [$_QEMU]"
      log_message e "$_msg"
   fi

   if [[ ! -x "$_RSYNC" ]]; then
      _ret=1
      _msg="Dependency: rsync cannot be found or executed in specified location [$_RSYNC]"
      log_message e "$_msg"
   fi

   if [[ ! -x "$_VIRSH" ]]; then
      _ret=1
      _msg="Dependency: virsh cannot be found or executed in specified location [$_VIRSH]"
      log_message e "$_msg"
   fi

   if (( _ret != 0 )); then
      return $_ret
   fi 

   _version="$(qemu_img_version)"
   if check_version "$_version" '1.2.0'; then
      _msg="Dependency: qemu_img version [$_version] is supported"
      log_message d "$_msg"
   else
      _ret=1
      _msg="Dependency: qemu_img version [$_version] is not supported - 1.2.0 or later is required"
      log_message e "$_msg"
   fi
   
   _version="$(qemu_version)"
   if check_version "$_version" '1.2.0'; then
      _msg="Dependency: qemu-system-x86_64 version [$_version] is supported"
      log_message d "$_msg"
   else
      _ret=1
      _msg="Dependency: qemu-system-x86_64 version [$_version] is not supported - 1.2.0 or later is required"
      log_message e "$_msg"
   fi

   _version="$(rsync_version)"
   if check_version "$_version" '2.6.0'; then
      _msg="Dependency: rsync version [$_version] is supported"
      log_message d "$_msg"
   else
      _ret=1
      _msg="Dependency: rsync version [$_version] is not supported - 2.6.0 or later is required"
      log_message e "$_msg"
   fi

   _version="$(libvirt_version)"
   if check_version "$_version" '0.9.13'; then
      _msg="Dependency: libVirt version [$_version] is supported"
      log_message d "$_msg"
   else
      _ret=1
      _msg="Dependency: libVirt version [$_version] is not supported - 0.9.13 or later is required"
      log_message e "$_msg"
   fi

   return $_ret
}

function set_domain_backup_mode_switches() {
   case "$_BACKUP_MODE" in
      "diff")
         _FLAG_COPY_SWITCH=0
         _FLAG_CONSOLIDATE_SWITCH=0
         _FLAG_ARCHIVE_SWITCH=0
         _FLAG_STOP_SWITCH=0
         ;;
      "copy")
         _FLAG_COPY_SWITCH=1
         _FLAG_CONSOLIDATE_SWITCH=0
         _FLAG_ARCHIVE_SWITCH=0
         _FLAG_STOP_SWITCH=0
         ;;
      "consolidate")
         _FLAG_COPY_SWITCH=0
         _FLAG_CONSOLIDATE_SWITCH=1
         _FLAG_ARCHIVE_SWITCH=0
         _FLAG_STOP_SWITCH=0
         ;;
      "archive")
         _FLAG_COPY_SWITCH=0
         _FLAG_CONSOLIDATE_SWITCH=1
         _FLAG_ARCHIVE_SWITCH=1
         _FLAG_STOP_SWITCH=1
         ;;
      "stop")
         _FLAG_COPY_SWITCH=0
         _FLAG_CONSOLIDATE_SWITCH=1
         _FLAG_ARCHIVE_SWITCH=0
         _FLAG_STOP_SWITCH=1
         ;;
   esac

   return 0
}

function get_all_domains() {
   # Try to get all domains array (virsh), otherwise return error
   local _ret
   local -a _cmd
   local _cmdFlat
   local _output
   local _outputFlat
   local _outputParsed
   local _msg
   local _thisLine

   _ret=0
   _ARR_DOMAIN=()

   if (( _FLAG_ALL_NON_RUNNING == 0 )); then
      _cmd=( "$_VIRSH" -q -r -c "$_QEMU_SYSTEM" list --all --name )
   else
      _cmd=( "$_VIRSH" -q -r -c "$_QEMU_SYSTEM" list --all --state-shutoff --name )
   fi
   _output=$("${_cmd[@]}" 2>&1)
   _ret=$?

   if (( _ret != 0 )); then
      _cmdFlat=$(printf '%q ' "${_cmd[@]}")
      _outputFlat="$(echo "$_output" | tr '\n' ' ')"
      _msg="Error getting all Domains - cmd=[$_cmdFlat] - return=[$_ret] - output=[$_outputFlat]"
      log_message e "$_msg"
      return $_ret
   fi

   _outputParsed="$(echo "$_output" | awk 'NF')"
   while IFS= read -r _thisLine; do
      if [[ -n "$_thisLine" ]]; then
         _ARR_DOMAIN+=("$_thisLine")
      fi
   done <<< "$_outputParsed"

   return $_ret
}

function check_domains_not_empty() {
   # Check domains array not empty, otherwise return error
   local _ret
   local _msg

   _ret=0

   if (( ${#_ARR_DOMAIN[*]} == 0 )); then
      _ret=1
      _msg="Domain list is empty - nothing to do"
      log_message e "$_msg"
      return $_ret
   fi

   return $_ret
}

function remove_excluded_domains() {
   # Remove selected domain exlusions from domains array
   local _thisExclusion
   local _flagDidExclusion
   local i
   local _msg

   for _thisExclusion in "${_ARR_EXCLUSION[@]}"; do
      _flagDidExclusion=0
      for i in "${!_ARR_DOMAIN[@]}"; do
         if [[ ${_ARR_DOMAIN[i]} == "$_thisExclusion" ]]; then
            unset '_ARR_DOMAIN[i]'
            _msg="Domain: [$_thisExclusion] - Excluded as requested"
            log_message v "$_msg"
            _flagDidExclusion=1
            break
         fi
      done

      if (( _flagDidExclusion == 0 )); then
         _msg="Domain: [$_thisExclusion] - Not excluded: not found in selected Domains"
         log_message w "$_msg"
      fi

   done

   # Re-index domains array
   _ARR_DOMAIN=("${_ARR_DOMAIN[@]}")

   return 0
}

function list_domains() {
   # List domains in domains array
   local _thisDomain
   local _selectedDomains
   local _msg

   for _thisDomain in "${_ARR_DOMAIN[@]}"; do
      _selectedDomains+="[$_thisDomain] "
   done

   _selectedDomains="${_selectedDomains%" "}" # trim
   _msg="Selected domains: $_selectedDomains"
   log_message i "$_msg"

   return 0
}

function skip_domain() {
   local _msg
   local _thisDomain

   _thisDomain="$1"

   _msg="Domain: [$_thisDomain] - Cannot backup this Domain due to error - Skipping this Domain"
   log_message e "$_msg"
   _FLAG_ERROR=1

   return 0
}

function skip_snapshots() {
   local _msg
   local _thisDomain

   _thisDomain="$1"

   _msg="Domain: [$_thisDomain] - Cannot snapshot this Domain due to error - Leaving disks unchanged"
   log_message e "$_msg"
   _FLAG_ERROR=1

   return 0
}

function lock_domain() {
   # Try to lock this Domain, otherwise return error
   local _ret
   local _thisDomain
   local _msg
   local _thisLockFile
   local _thisLockFD

   _ret=0
   _thisDomain="$1"
   _thisLockFile="$_LOCK_DIR/$_thisDomain.SnapBak.lock"

   # Try to open lockfile with dynamic FD, otherwise return error
   if ! exec {_thisLockFD}>"$_thisLockFile"; then
      _ret=1
      _msg="Domain: [$_thisDomain] - Could not access lockfile: [$_thisLockFile]"
      log_message e "$_msg"
      return $_ret
   fi

   if flock -n "$_thisLockFD"; then
      # Write proc id to lockfile
      printf '%s\n' "$$" >&"$_thisLockFD"
      # Set global lockFD variable to dynamic FD in use
      _LOCK_FD=$_thisLockFD
      _msg="Domain: [$_thisDomain] - Lock [FD=${_LOCK_FD}] on [$_thisLockFile] acquired"
      log_message d "$_msg"
   else
      # Release the dynamic FD and return error
      exec ${_thisLockFD}>&- 2>/dev/null || true
      _ret=1
      _msg="Domain: [$_thisDomain] - Another instance of LibvirtSnapBak has locked this Domain - Delete lockfile manually if required"
      log_message e "$_msg"
      return $_ret
   fi

   return $_ret
}

function unlock_domain() {
   # Try to unlock this Domain, otherwise return error
   local _ret
   local _thisDomain
   local _msg
   local _thisLockFile
   
   _ret=0
   _thisDomain="$1"
   _thisLockFile="$_LOCK_DIR/$_thisDomain.SnapBak.lock"

   # Release the dynamic FD (as set by lock_domain) on lockfile
   if (( _LOCK_FD != 0 )); then
      eval "exec ${_LOCK_FD}>&- 2>/dev/null" || true
      _msg="Domain: [$_thisDomain] - Lock [FD=${_LOCK_FD}] on [$_thisLockFile] released"
      log_message d "$_msg"
      _LOCK_FD=0
   fi

   # If lockfile still exists
   if [[ -n "$_thisLockFile" ]]; then
      # Delete lockfile otherwise log error
      rm -f -- "$_thisLockFile"
      _ret=$?
      if (( _ret != 0 )); then
         _msg="Domain: [$_thisDomain] - Could not delete lock file: [$_thisLockFile]"
         log_message e "$_msg"
      fi
   fi

   return $_ret
}

function get_domain_block_devices() {
   # Try to get all Block Devices for this Domain (virsh), otherwise return error
   local _ret
   local _thisDomain
   local -a _cmd
   local _cmdFlat
   local _output
   local _outputFlat
   local _outputParsed
   local _msg
   local _thisLine

   _ret=0
   _thisDomain="$1"
   _ARR_BLOCK_DEVICE=()
   
   _cmd=( "$_VIRSH" -r -c "$_QEMU_SYSTEM" domblklist "$_thisDomain" )
   _output=$("${_cmd[@]}" 2>&1)
   _ret=$?

   if (( _ret != 0 )); then
      _cmdFlat=$(printf '%q ' "${_cmd[@]}")
      _outputFlat="$(echo "$_output" | tr '\n' ' ')"
      _msg="Domain: [$_thisDomain] - Error getting Block Devices - cmd: [$_cmdFlat] - error: [$_ret] - output: [$_outputFlat]"
      log_message e "$_msg"
      return $_ret
   fi

   _outputParsed="$(echo "$_output" | awk 'NR > 2 && NF {print $2}')"
   while IFS= read -r _thisLine; do
      if [[ -n "$_thisLine" ]]; then
         _ARR_BLOCK_DEVICE+=("$_thisLine")
      fi
   done <<< "$_outputParsed"

   return $_ret
}

function check_block_devices_not_empty() {
   # Check block devices array not empty, otherwise return error
   local _ret
   local _msg

   _ret=0

   if (( ${#_ARR_BLOCK_DEVICE[*]} == 0 )); then
      _ret=1
      _msg="Domain: [$_thisDomain] - No storage devices detected - nothing to do"
      log_message e "$_msg"
      return $_ret
   fi

   return $_ret
}

function get_file_info() {
   # Try to get file info for this device, otherwise return error
   local _ret
   local _thisDomain
   local _thisFile
   local _flagFileIsBlockDevice
   local _thisFileSourceName
   local _thisFileSourcePath
   local -a _cmd
   local _cmdFlat
   local _output
   local _outputFlat
   local _msg
   local _thisFileBackupPath
   local _flagFileHasBackingFile
   local _thisFileInfo
   local _thisFileFormat
   local _thisBackingFileName
   local _thisBackingFilePath
   local _thisBackingFileBackupPath
   local _thisBackingFileFormat
  
   _thisDomain="$1"
   _thisFile="$2"
   _flagFileIsBlockDevice=$3

   _ret=0
   _flagFileHasBackingFile=0
   _thisBackingFileName=""
   _thisBackingFilePath=""
   _thisBackingFileBackupPath=""
   _thisBackingFileFormat=""

   # Set File and Source Path
   _thisFileSourceName="$(basename "$_thisFile")"
   _thisFileSourcePath="$(dirname "$_thisFile")"

   # Check permissions on device and dir, otherwise return error
   if [[ ! -r "$_thisFileSourcePath" ]] || [[ ! -x "$_thisFileSourcePath" ]]; then
      _ret=1
      _msg="Domain: [$_thisDomain] - Error: read and execute permissions required on all storage directories [$_thisFileSourcePath]"
      log_message e "$_msg"
      return $_ret
   fi
   if [[ ! -r "$_thisFile" ]] ; then
      _ret=1
      _msg="Domain: [$_thisDomain] - Error: read permission required on all storage files [$_thisFile]"
      log_message e "$_msg"
      return $_ret
   fi

    # Set Backup Path
   if (( _FLAG_ARCHIVE_SWITCH != 0 )); then
      _thisFileBackupPath="$_BACKUP_DIR/$_thisDomain/Archive-$_DIFF_TIMESTAMP$_thisFileSourcePath"
   elif (( _FLAG_COPY_SWITCH != 0 )); then
      _thisFileBackupPath="$_BACKUP_DIR/$_thisDomain/Copy-$_DIFF_TIMESTAMP$_thisFileSourcePath"
   else
      _thisFileBackupPath="$_BACKUP_DIR/$_thisDomain$_thisFileSourcePath"
   fi

   # Try to get file info (qemu-img), otherwise return error
   _cmd=( "$_QEMU_IMG" info "$_thisFile" --force-share )
   _output=$("${_cmd[@]}" 2>&1)
   _ret=$?

   if (( _ret != 0 )); then
      _cmdFlat=$(printf '%q ' "${_cmd[@]}")
      _outputFlat="$(echo "$_output" | tr '\n' ' ')"
      _msg="Domain: [$_thisDomain] - Error getting File info - cmd: [$_cmdFlat] - error: [$_ret] - output: [$_outputFlat]"
      log_message e "$_msg"
      return $_ret
   fi
   
   # Parse file info and set other properties
   _thisFileInfo="$_output"
   _thisFileFormat="$(echo "$_thisFileInfo" | grep -oP 'file format: \K\S+' | head -n 1)"
   _THIS_BACKING_FILE="$(echo "$_thisFileInfo" | grep -oP 'backing file: \K\S+' | head -n 1)"
   if [[ -n "$_THIS_BACKING_FILE" ]]; then
      _flagFileHasBackingFile=1
      _thisBackingFileName="$(basename "$_THIS_BACKING_FILE")"
      _thisBackingFilePath="$(dirname "$_THIS_BACKING_FILE")"
      # Set Backing File Target Path
      if (( _FLAG_ARCHIVE_SWITCH != 0 )); then
         _thisBackingFileBackupPath="$_BACKUP_DIR/$_thisDomain/Archive-$_DIFF_TIMESTAMP$_thisBackingFilePath"
      elif (( _FLAG_COPY_SWITCH != 0 )); then
         _thisBackingFileBackupPath="$_BACKUP_DIR/$_thisDomain/Copy-$_DIFF_TIMESTAMP$_thisBackingFilePath"
      else
         _thisBackingFileBackupPath="$_BACKUP_DIR/$_thisDomain$_thisBackingFilePath"
      fi
      # Set Backing File Format
      _thisBackingFileFormat="$(echo "$_thisFileInfo" | grep -oP 'file format: \K\S+' | sed -n '2p')"
   fi
   if echo "$_thisFileInfo" | grep -q "bitmaps:"; then
      _FLAG_DOMAIN_HAS_BITMAP=1
   fi

   # Add this file's properties to arrays
   _ARR_FILE+=("$_thisFileSourceName")
   _ARR_FILE_FORMAT+=("$_thisFileFormat")
   _ARR_FILE_SOURCE_PATH+=("$_thisFileSourcePath")
   _ARR_FILE_BACKUP_PATH+=("$_thisFileBackupPath")
   _ARR_FILE_FLAG_IS_BLOCK_DEVICE+=("$_flagFileIsBlockDevice")
   _ARR_FILE_FLAG_HAS_BACKING_FILE+=("$_flagFileHasBackingFile")
   _ARR_FILE_BACKING_FILE+=("$_thisBackingFileName")
   _ARR_FILE_BACKING_PATH+=("$_thisBackingFileBackupPath")
   _ARR_FILE_BACKING_FORMAT+=("$_thisBackingFileFormat")

   return $_ret
}

function get_domain_storage() {
   # Try to get all storage files for this Domain, otherwise return error
   local _thisDomain
   local _thisBlockDevice
   local _thisFile
   local _flagFileIsBlockDevice

   _thisDomain="$1"

   get_domain_block_devices "$_thisDomain" || return 1

   check_block_devices_not_empty "$_thisDomain" || return 1

   _ARR_FILE=()
   _ARR_FILE_FORMAT=()
   _ARR_FILE_SOURCE_PATH=()
   _ARR_FILE_BACKUP_PATH=()
   _ARR_FILE_FLAG_IS_BLOCK_DEVICE=()
   _ARR_FILE_FLAG_HAS_BACKING_FILE=()
   _ARR_FILE_BACKING_FILE=()
   _ARR_FILE_BACKING_PATH=()
   _ARR_FILE_BACKING_FORMAT=()
   _ARR_DOMAIN_CLEANUP_PATH=()
   _FLAG_DOMAIN_HAS_BITMAP=0

   # For each Block Device in Domain
   for _thisBlockDevice in "${_ARR_BLOCK_DEVICE[@]}"; do

      _thisFile="$_thisBlockDevice"
      _flagFileIsBlockDevice=1

      # Loop through this file and all backing files to get file info, otherwise return error
      while [[ -n "$_thisFile" ]]; do
         get_file_info "$_thisDomain" "$_thisFile" $_flagFileIsBlockDevice || return 1
         # This file = Backing File from preceding iteration (empty if none)
         _thisFile="$_THIS_BACKING_FILE"
         _flagFileIsBlockDevice=0
      done
   done

   return 0
}

function get_domain_snapshots() {
   # Try to get all Snapshots for this Domain (virsh), otherwise return error
   local _thisDomain
   local _ret   
   local _cmd
   local _output
   local _outputFlat
   local _outputParsed
   local _msg
   local _thisLine

   _thisDomain="$1"

   _ret=0
   _ARR_SNAPSHOT=()
   _FLAG_DOMAIN_HAS_TEMP=0
   _FLAG_DOMAIN_HAS_SNAPSHOT=0
   _FLAG_DOMAIN_HAS_MANUAL=0
   _FLAG_DOMAIN_HAS_DIFF=0
   _FLAG_DOMAIN_HAS_REVERTED=0

   _cmd="$_VIRSH -r -c $_QEMU_SYSTEM snapshot-list $_thisDomain --topological --name"
   _output="$($_cmd 2>&1)"
   _ret=$?

   if (( _ret != 0 )); then
      _outputFlat="$(echo "$_output" | tr '\n' ' ')"
      _msg="Domain: [$_thisDomain] - Error getting Snapshots - cmd: [$_cmd] - error: [$_ret] - output: [$_outputFlat]"
      log_message e "$_msg"
      return $_ret
   fi

   _outputParsed="$(echo "$_output" | awk 'NF')"
   while IFS= read -r _thisLine; do
      if [[ -n "$_thisLine" ]]; then
         _ARR_SNAPSHOT+=("$_thisLine")
         _FLAG_DOMAIN_HAS_SNAPSHOT=1
      fi
   done <<< "$_outputParsed"

   return $_ret
}

function check_domain_snapshots() {
   # Try to check all Snapshots for this Domain (virsh), otherwise return error
   local _thisDomain
   local _ret
   local _cmd
   local _output
   local _outputFlat
   local _msg
   local _thisSnapshot
   local _thisSnapshotFile

   _thisDomain="$1"
   _ret=0

   if (( _FLAG_DOMAIN_HAS_SNAPSHOT == 1 )); then
      for _thisSnapshot in "${_ARR_SNAPSHOT[@]}"; do

         if [[ "$_thisSnapshot" == "SnapBakTemp" ]]; then
            _FLAG_DOMAIN_HAS_TEMP=1
            _msg="Domain: [$_thisDomain] - Remnant SnapBakTemp snapshot detected - will be consolidated into base image"
            log_message v "$_msg"
            return $_ret
         fi
         if [[ "$_thisSnapshot" != "SnapBakDiff" ]]; then
            _FLAG_DOMAIN_HAS_MANUAL=1
            return $_ret
         fi
         if [[ "$_thisSnapshot" == "SnapBakDiff" ]]; then
            _FLAG_DOMAIN_HAS_DIFF=1

            _cmd="$_VIRSH -r -c $_QEMU_SYSTEM snapshot-dumpxml $_thisDomain $_thisSnapshot"
            _output="$($_cmd 2>&1)"
            _ret=$?

            if (( _ret != 0 )); then
               _outputFlat="$(echo "$_output" | tr '\n' ' ')"
               _msg="Domain: [$_thisDomain] - Error getting Snapshot XML - cmd: [$_cmd] - error: [$_ret] - output: [$_outputFlat]"
               log_message e "$_msg"
               return $_ret
            fi

            _thisSnapshotFile="$(echo "$_output" | awk -F"'" '/<disks>/,/<\/disks>/ {if (/<source file=/) {print $2}}')"
            if [[ -n "$_thisSnapshotFile" ]] && [[ "$_thisSnapshotFile" != *"SnapBakDiff"* ]]; then
               _FLAG_DOMAIN_HAS_REVERTED=1
               _msg="Domain: [$_thisDomain] - Reverted Diff snapshot detected - will be consolidated into base image"
               log_message v "$_msg"
            fi
         fi
      done
   fi

   return $_ret
}

function check_domain_backup_mode() {
   local _thisDomain
   local _msg

   _thisDomain="$1"

   # If not has Snapshot and stop switch = 0 (mode <> archive or stop)
   if (( _FLAG_DOMAIN_HAS_SNAPSHOT == 0 )) && (( _FLAG_STOP_SWITCH == 0 )); then
      _msg="Domain: [$_thisDomain] - No existing Diff snapshot detected - New Diff snapshot will be created"
      log_message v "$_msg"
      # Set consolidate switch = 1 for this domain (to force cleanup of any stray orphan files)
      _FLAG_CONSOLIDATE_SWITCH=1
   fi

   return 0
}

function check_domain_compatibility() {
   local _thisDomain
   local _msg

   _thisDomain="$1"

   # Warn incompatible if has Manual 
   if (( _FLAG_DOMAIN_HAS_MANUAL == 1 )); then
      # If there already is a diff, then warn cannot change Diff
      if (( _FLAG_DOMAIN_HAS_DIFF == 1 )); then
         _msg="Domain: [$_thisDomain] - Incompatible state for differential: Manual snapshot detected - Leaving existing Diff unchanged"
         log_message w "$_msg"
      # Else (if no diff already), if stop swtich = 0 (mode <> archive or stop), then warn cannot create new Diff
      elif (( _FLAG_STOP_SWITCH == 0 )); then
         _msg="Domain: [$_thisDomain] - Incompatible state for differential: Manual snapshot detected - Cannot create new Diff"
         log_message w "$_msg"
      fi
   fi

   # Warn incompatible if has Bitmap
   if (( _FLAG_DOMAIN_HAS_BITMAP == 1 )); then
      # If there already is a diff, then warn cannot change Diff
      if (( _FLAG_DOMAIN_HAS_DIFF == 1 )); then
         _msg="Domain: [$_thisDomain] - Incompatible state for differential: Checkpoint bitmap detected - Leaving existing Diff unchanged"
         log_message w "$_msg"
      # Else (if no diff already), if stop swtich = 0 (mode <> archive or stop), then warn cannot create new Diff
      elif (( _FLAG_STOP_SWITCH == 0 )); then
         _msg="Domain: [$_thisDomain] - Incompatible state for differential: Checkpoint bitmap detected - Cannot create new Diff"
         log_message w "$_msg"
      fi
   fi

   return 0
}

function delete_snapshot() {
   # Try to delete Diff Snapshot for this Domain (virsh), otherwise return error
   local _thisDomain
   local _thisSnapshot
   local _ret
   local -a _cmd
   local _cmdFlat
   local _output
   local _outputFlat
   local _msg

   _thisDomain="$1"
   _thisSnapshot="$2"
   _ret=0

   _cmd=( "$_VIRSH" -c "$_QEMU_SYSTEM" snapshot-delete "$_thisDomain" "$_thisSnapshot" )
   _output=$("${_cmd[@]}" 2>&1)
   _ret=$?

   if (( _ret != 0 )); then
      _cmdFlat=$(printf '%q ' "${_cmd[@]}")
      _outputFlat="$(echo "$_output" | tr '\n' ' ')"
      _msg="Domain: [$_thisDomain] - Error deleting Snapshot - cmd: [$_cmdFlat] - error: [$_ret] - output: [$_outputFlat]"
      log_message e "$_msg"
      return $_ret
   fi

   return $_ret
}

function create_snapshot() {
   # Try to create Diff Snapshot for this Domain (virsh), otherwise return error
   local _thisDomain
   local _thisSnapshot
   local _ret
   local -a _cmd
   local _cmdFlat
   local _output
   local _outputFlat
   local _msg

   _thisDomain="$1"
   _thisSnapshot="$2"
   _ret=0

   _cmd=( "$_VIRSH" -c "$_QEMU_SYSTEM" snapshot-create-as "$_thisDomain" "$_thisSnapshot" --disk-only --atomic --quiesce )
   _output=$("${_cmd[@]}" 2>&1)
   _ret=$?

   if (( _ret != 0 )); then
      _cmdFlat=$(printf '%q ' "${_cmd[@]}")
      _outputFlat="$(echo "$_output" | tr '\n' ' ')"
      _msg="Domain: [$_thisDomain] - Error creating Snapshot - cmd: [$_cmdFlat] - error: [$_ret] - output: [$_outputFlat]"
      log_message w "$_msg"
      return $_ret
   fi

   return $_ret
}

function delete_temp_snapshot() {
   local _thisDomain
   local _thisSnapshot
   local _ret
   local _msg

   _thisDomain="$1"
   _ret=0
   
   # Delete remnant temp snapshot and recheck
   for _thisSnapshot in "${_ARR_SNAPSHOT[@]}"; do
      if [[ "$_thisSnapshot" == "SnapBakTemp" ]]; then
         _ret=0
         delete_snapshot "$_thisDomain" SnapBakTemp || _ret=1
         if (( _ret == 0 )); then
            _msg="Domain: [$_thisDomain] - Remnant SnapBakTemp snapshot consolidated into base image"
            log_message v "$_msg"
            break
         else
            _msg="Domain: [$_thisDomain] - Error: could not consolidate remnant SnapBakTemp snapshot into base image"
            log_message e "$_msg"
            return 1
         fi
      fi
   done
   get_domain_snapshots "$_thisDomain" || return 1
   check_domain_snapshots "$_thisDomain" || return 1

   return 0
}

function do_diff() {
   local _thisDomain
   local _thisSnapshot
   local _ret
   local _msg

   _thisDomain="$1"
   _ret=0

   # Update timestamp for diff
   _DIFF_TIMESTAMP="$(date "+%Y%m%d-%H%M%S")"

   # Order matters here:
   
   # If Has Reverted then delete diff snapshot and recheck
   if (( _FLAG_DOMAIN_HAS_REVERTED == 1 )); then
      for _thisSnapshot in "${_ARR_SNAPSHOT[@]}"; do
         if [[ "$_thisSnapshot" == "SnapBakDiff" ]]; then
            _ret=0
            delete_snapshot "$_thisDomain" SnapBakDiff || _ret=1
            if (( _ret == 0 )); then
               _msg="Domain: [$_thisDomain] - Reverted Diff snapshot consolidated into base image"
               log_message v "$_msg"
               break
            else
               _msg="Domain: [$_thisDomain] - Error: could not consolidate Diff snapshot into base image"
               log_message e "$_msg"
               return 1
            fi
         fi
      done
      get_domain_snapshots "$_thisDomain" || return 1
      check_domain_snapshots "$_thisDomain" || return 1
   fi

   # If Has Diff AND consolidate switch = 1 then delete diff snapshot and recheck
   if (( _FLAG_DOMAIN_HAS_DIFF == 1 )) && (( _FLAG_CONSOLIDATE_SWITCH == 1 )); then
      for _thisSnapshot in "${_ARR_SNAPSHOT[@]}"; do
         if [[ "$_thisSnapshot" == "SnapBakDiff" ]]; then
            _ret=0
            delete_snapshot "$_thisDomain" SnapBakDiff || _ret=1
            if (( _ret == 0 )); then
               _msg="Domain: [$_thisDomain] - Existing Diff snapshot detected and consolidated into base image"
               log_message v "$_msg"
               break
            else
               _msg="Domain: [$_thisDomain] - Error: could not consolidate Diff snapshot into base image"
               log_message e "$_msg"
               return 1
            fi
         fi
      done
      get_domain_snapshots "$_thisDomain" || return 1
      check_domain_snapshots "$_thisDomain" || return 1
   fi

   # If Has Diff then do nothing
   if (( _FLAG_DOMAIN_HAS_DIFF == 1 )); then
      _msg="Domain: [$_thisDomain] - Existing Diff snapshot detected and retained"
      log_message v "$_msg"
   fi

   # If Has Diff = 0 AND stop switch = 0 then create diff snapshot
   if (( _FLAG_DOMAIN_HAS_DIFF == 0 )) && (( _FLAG_STOP_SWITCH == 0 )); then
      create_snapshot "$_thisDomain" SnapBakDiff || _ret=1
      if (( _ret == 0 )); then
         _msg="Domain: [$_thisDomain] - New Diff snapshot created"
         log_message v "$_msg"
      else
         _msg="Domain: [$_thisDomain] - Error: could not create new Diff snapshot"
         log_message e "$_msg"
         return 1
      fi
   fi

   return 0
}

function get_domain_state() {
   # Try to get domain state (virsh), otherwise return error
   local _thisDomain
   local _ret
   local -a _cmd
   local _cmdFlat
   local _output
   local _outputFlat
   local _msg
   local _thisDomainState

   _thisDomain="$1"
   _ret=0

   _cmd=( "$_VIRSH" -q -r -c "$_QEMU_SYSTEM" domstate "$_thisDomain" )
   _output=$("${_cmd[@]}" 2>&1)
   _ret=$?
   
   if (( _ret != 0 )); then
      _cmdFlat=$(printf '%q ' "${_cmd[@]}")
      _outputFlat="$(echo "$_output" | tr '\n' ' ')"
      _msg="Error getting Domain state - cmd=[$_cmdFlat] - return=[$_ret] - output=[$_outputFlat]"
      log_message e "$_msg"
      return $_ret
   fi

   _thisDomainState=$(echo "$_output" | awk 'NF')
   if [[ "$_thisDomainState" != "shut off" ]]; then
      _FLAG_THIS_DOMAIN_RUNNING=1
   fi

   return $_ret
}

function suspend_domain() {
   # Try to suspend domain (virsh), otherwise return error
   local _thisDomain
   local _ret
   local -a _cmd
   local _cmdFlat
   local _output
   local _outputFlat
   local _msg

   _thisDomain="$1"
   _ret=0

   _cmd=( "$_VIRSH" -q -c "$_QEMU_SYSTEM" suspend "$_thisDomain" )
   _output=$("${_cmd[@]}" 2>&1)
   _ret=$?
   
   if (( _ret != 0 )); then
      _cmdFlat=$(printf '%q ' "${_cmd[@]}")
      _outputFlat="$(echo "$_output" | tr '\n' ' ')"
      _msg="Error pausing Domain - cmd=[$_cmdFlat] - return=[$_ret] - output=[$_outputFlat]"
      log_message e "$_msg"
      return $_ret
   fi

   return $_ret
}

function resume_domain() {
   # Try to resume domain (virsh), otherwise return error
   local _thisDomain
   local _ret
   local -a _cmd
   local _cmdFlat
   local _output
   local _outputFlat
   local _msg

   _thisDomain="$1"
   _ret=0

   _cmd=( "$_VIRSH" -q -c "$_QEMU_SYSTEM" resume "$_thisDomain" )
   _output=$("${_cmd[@]}" 2>&1)
   _ret=$?
   
   if (( _ret != 0 )); then
      _cmdFlat=$(printf '%q ' "${_cmd[@]}")
      _outputFlat="$(echo "$_output" | tr '\n' ' ')"
      _msg="Error resuming Domain - cmd=[$_cmdFlat] - return=[$_ret] - output=[$_outputFlat]"
      log_message e "$_msg"
      return $_ret
   fi

   return $_ret
}

function sync_file_to_backup_if_newer() {
   local _thisDomain
   local i
   local _ret
   local -a _cmd
   local _cmdFlat
   local _output
   local _outputFlat
   local _msg

   _thisDomain="$1"
   i=$2
   _ret=0

   # Replicate full Source File path hierarchy within Backup Directory using mkdir (if not exists)
   _cmd=( mkdir -p "${_ARR_FILE_BACKUP_PATH[i]}" )
   _output=$("${_cmd[@]}" 2>&1)
   _ret=$?

   if (( _ret != 0 )); then
      _cmdFlat=$(printf '%q ' "${_cmd[@]}")
      _outputFlat="$(echo "$_output" | tr '\n' ' ')"
      _msg="Domain: [$_thisDomain] - Error creating Backup Directory - cmd: [$_cmdFlat] - error: [$_ret] - output: [$_outputFlat]"
      log_message e "$_msg"
      return $_ret
   fi

   # Do Diff History if source file is Diff AND is Block Device (= not BackingFile) AND copy switch = 0 AND consolidate switch = 0 (mode=diff)
   if [[ "${_ARR_FILE[i]}" == *"SnapBakDiff" ]] && (( _ARR_FILE_FLAG_IS_BLOCK_DEVICE[i] == 1 )) && (( _FLAG_COPY_SWITCH == 0 )) && (( _FLAG_CONSOLIDATE_SWITCH == 0 )); then

      # If previous Diff already exists in backup dir
      if [[ -f "${_ARR_FILE_BACKUP_PATH[i]}/${_ARR_FILE[i]}" ]]; then

         # Read previous Diff Timestamp from .marker (if exists - it should)
         if [[ -f "${_ARR_FILE_BACKUP_PATH[i]}/.marker" ]]; then
            _PREV_DIFF_TIMESTAMP=$(<"${_ARR_FILE_BACKUP_PATH[i]}/.marker")
         fi

         # Compare Diff with existing Diff, and if different then
         if ! cmp -s "${_ARR_FILE_SOURCE_PATH[i]}/${_ARR_FILE[i]}" "${_ARR_FILE_BACKUP_PATH[i]}/${_ARR_FILE[i]}"; then

            # Create DiffHistory Dir in Backup Dir using mkdir (if not exists)
            _cmd=( mkdir -p "${_ARR_FILE_BACKUP_PATH[i]}"/_DiffHistory )
            _output=$("${_cmd[@]}" 2>&1)
            _ret=$?

            if [[ $_ret -ne 0 ]]; then
               _cmdFlat=$(printf '%q ' "${_cmd[@]}")
               _outputFlat="$(echo "$_output" | tr '\n' ' ')"
               _msg="Domain: [$_thisDomain] - Error creating Diff History dir - cmd: [$_cmdFlat] - error: [$_ret] - output: [$_outputFlat]"
               log_message e "$_msg"
               return $_ret
            fi

            # Move previous Diff to DiffHistory dir
            _cmd=( mv "${_ARR_FILE_BACKUP_PATH[i]}"/"${_ARR_FILE[i]}" "${_ARR_FILE_BACKUP_PATH[i]}"/_DiffHistory/"${_ARR_FILE[i]}"-"$_PREV_DIFF_TIMESTAMP" )
            _output=$("${_cmd[@]}" 2>&1)
            _ret=$?

            if [[ $_ret -ne 0 ]]; then
               _cmdFlat=$(printf '%q ' "${_cmd[@]}")
               _outputFlat="$(echo "$_output" | tr '\n' ' ')"
               _msg="Domain: [$_thisDomain] - Error moving previous Diff to Diff History dir - cmd: [$_cmdFlat] - error: [$_ret] - output: [$_outputFlat]"
               log_message e "$_msg"
               return $_ret
            fi
         fi
      fi
   fi

   # Sync Source File to Backup Directory using rsync (overwrite if source is newer)
   echo "   Syncing file: ${_ARR_FILE[i]} -> ${_ARR_FILE_BACKUP_PATH[i]}" | tee -a "$_LOG_FILE"
   _cmd=( "$_RSYNC" -u -h --progress "${_ARR_FILE_SOURCE_PATH[i]}"/"${_ARR_FILE[i]}" "${_ARR_FILE_BACKUP_PATH[i]}"/ )
   $_RSYNC -u -h --progress "${_ARR_FILE_SOURCE_PATH[i]}/${_ARR_FILE[i]}" "${_ARR_FILE_BACKUP_PATH[i]}/"
   _ret=$?

   if (( _ret != 0 )); then
      _cmdFlat=$(printf '%q ' "${_cmd[@]}")
      _msg="Domain: [$_thisDomain] - Error syncing file to Backup Directory - cmd: [$_cmdFlat] - error: [$_ret]"
      log_message e "$_msg"
      return $_ret
   fi

   # Write Diff Timestamp to .marker
   echo "$_DIFF_TIMESTAMP" > "${_ARR_FILE_BACKUP_PATH[i]}"/.marker

   return $_ret
}

function rebase_backup_backing_file() {
   local _thisDomain
   local i
   local _cmd
   local _ret
   local _msg

   _thisDomain="$1"
   i=$2
   _ret=0

   # Rebase File in Backup Directory using qemu-img
   _msg="   Rebasing file: ${_ARR_FILE[i]} -> Backing File: ${_ARR_FILE_BACKING_PATH[i]}/${_ARR_FILE_BACKING_FILE[i]}"
   echo "$_msg" | tee -a "$_LOG_FILE"

   _cmd="$_QEMU_IMG rebase -p -F ${_ARR_FILE_BACKING_FORMAT[i]} -b ${_ARR_FILE_BACKING_PATH[i]}/${_ARR_FILE_BACKING_FILE[i]} ${_ARR_FILE_BACKUP_PATH[i]}/${_ARR_FILE[i]}"
   $_QEMU_IMG rebase -p -F "${_ARR_FILE_BACKING_FORMAT[i]}" -b "${_ARR_FILE_BACKING_PATH[i]}/${_ARR_FILE_BACKING_FILE[i]}" "${_ARR_FILE_BACKUP_PATH[i]}/${_ARR_FILE[i]}"
   _ret=$?

   if (( _ret != 0 )); then
      _msg="Domain: [$_thisDomain] - Error rebasing file in Backup Directory - cmd: [$_cmd] - error: [$_ret]"
      log_message e "$_msg"
      return $_ret
   fi

   return $_ret
}

function get_cleanup_paths () {
   local _thisCleanupPath
   local _thisFileBackupPath
   local _gotThisCleanupPath

   # Add distinct Backup Paths to Cleanup Path array
   for _thisFileBackupPath in "${_ARR_FILE_BACKUP_PATH[@]}"; do
      _gotThisCleanupPath=0 

      for _thisCleanupPath in "${_ARR_DOMAIN_CLEANUP_PATH[@]}"; do
         if [[ "$_thisCleanupPath" == "$_thisFileBackupPath" ]]; then
            _gotThisCleanupPath=1
            break
         fi
      done

      if (( _gotThisCleanupPath == 0 )); then
         _ARR_DOMAIN_CLEANUP_PATH+=("$_thisFileBackupPath")
      fi
   done

   return 0
}

function prune_diff_history_dir() {
   local _thisDomain
   local _ret
   local -a _cmd
   local _cmdFlat
   local _output
   local _outputFlat
   local _msg
   local _thisCleanupPath
   local _thisDiffHistDir
   local _thisDiffHistFileCount
   local _thisDiffHistFileList
   local _arrPruneFiles
   local _pruneFile
   local _pruneFileName

   _thisDomain="$1"
   _ret=0

   _arrPruneFiles=()
   
   for _thisCleanupPath in "${_ARR_DOMAIN_CLEANUP_PATH[@]}"; do
      _thisDiffHistDir="$_thisCleanupPath/_DiffHistory"

      if [[ -e "$_thisDiffHistDir" ]]; then
         _thisDiffHistFileCount=$(find "$_thisDiffHistDir" -maxdepth 1 -type f | wc -l)
         if (( _thisDiffHistFileCount > _MAX_DIFFS )); then
            _thisDiffHistFileList=$(find "$_thisDiffHistDir" -maxdepth 1 -type f | 
               awk -F '-' '{print $(NF-1) "-" $NF, $0}' | 
               sort -k1,1r | 
               tail -n +$(( _MAX_DIFFS + 1 )) | 
               cut -d ' ' -f 2-)

            IFS=$'\n' read -rd '' -a _arrPruneFiles <<< "$_thisDiffHistFileList"

            for _pruneFile in "${_arrPruneFiles[@]}"; do
               _pruneFileName=$(basename "$_pruneFile")
               _cmd=( rm -f -- "$_pruneFile" )
               _output=$("${_cmd[@]}" 2>&1)
               _ret=$?

               if (( _ret != 0 )); then
                  _cmdFlat=$(printf '%q ' "${_cmd[@]}")
                  _outputFlat="$(echo "$_output" | tr '\n' ' ')"
                  _msg="Domain: [$_thisDomain] - Error pruning Diff History - cmd: [$_cmdFlat] - error: [$_ret] - output: [$_output]"
                  log_message e "$_msg"
                  return $_ret
               else
                  _msg="Domain: [$_thisDomain] - Pruning Diff History: $_pruneFileName"
                  log_message v "$_msg"
               fi

            done
         fi
      fi
   done

   return $_ret
}

function delete_diff_history_dir () {
   local _thisDomain
   local _ret
   local -a _cmd
   local _cmdFlat
   local _output
   local _outputFlat
   local _msg
   local _thisCleanupPath
   local _thisDiffHistDir

   _thisDomain="$1"
   _ret=0
   
   for _thisCleanupPath in "${_ARR_DOMAIN_CLEANUP_PATH[@]}"; do
      _thisDiffHistDir="$_thisCleanupPath/_DiffHistory"

      if [[ -e "$_thisDiffHistDir" ]]; then
         _cmd=( rm -r -f -- "$_thisDiffHistDir" )
         _output=$("${_cmd[@]}" 2>&1)
         _ret=$?

         if (( _ret != 0 )); then
            _cmdFlat=$(printf '%q ' "${_cmd[@]}")
            _outputFlat="$(echo "$_output" | tr '\n' ' ')"
            _msg="Domain: [$_thisDomain] - Error deleting DiffHistory Directory - cmd: [$_cmdFlat] - error: [$_ret] - output: [$_output]"
            log_message e "$_msg"
            return $_ret
         else
            _msg="Domain: [$_thisDomain] - Deleted DiffHistory directory: $_thisDiffHistDir"
            log_message v "$_msg"
         fi
      fi
   done

   return $_ret
}

function delete_orphan_files_in_backup_dir () {
   local _thisDomain
   local _ret
   local -a _cmd
   local _cmdFlat
   local _output
   local _outputFlat
   local _msg
   local _thisCleanupPath
   local _thisCheckFile
   local m
   local _gotCheckFile
   local _thisCheckFileName

   _thisDomain="$1"
   _ret=0

   # For each CleanupPath
   for _thisCleanupPath in "${_ARR_DOMAIN_CLEANUP_PATH[@]}"; do
      # For each CheckFile in CleanupPath directory (* so all files)
      for _thisCheckFile in "$_thisCleanupPath"/*; do
         _gotCheckFile=0
         # If this CheckFile is a file (not a dir)
         if [[ -f "$_thisCheckFile" ]]; then
            # if this CheckFileName <> .marker AND this CheckFile is a file (not a dir)
            _thisCheckFileName=$(basename "$_thisCheckFile")
            if [[ "$_thisCheckFileName" != ".marker" ]]; then
               # For each File in File Array
               for (( m=0; m<${#_ARR_FILE[@]}; m++ )); do
                  # If match found then skip this CheckFile
                  if [[ "$_thisCheckFile" == "${_ARR_FILE_BACKUP_PATH[m]}/${_ARR_FILE[m]}" ]]; then
                     _gotCheckFile=1
                     break
                  fi
               done
               # If no match found
               if (( _gotCheckFile == 0 )); then
                  # Delete CheckFile
                  _cmd=( rm -f -- "$_thisCheckFile" )
                  _output=$("${_cmd[@]}" 2>&1)
                  _ret=$?

                  if (( _ret != 0 )); then
                     _cmdFlat=$(printf '%q ' "${_cmd[@]}")
                     _outputFlat="$(echo "$_output" | tr '\n' ' ')"
                     _msg="Domain: [$_thisDomain] - Error deleting orphaned file - cmd: [$_cmdFlat] - error: [$_ret] - output: [$_output]"
                     log_message e "$_msg"
                     return $_ret
                  else
                     _msg="Domain: [$_thisDomain] - Deleted orphaned file: $_thisCheckFile"
                     log_message v "$_msg"
                  fi
               fi
            fi
         fi
      done
   done

   return $_ret
}

function do_snapshots() {
   local _thisDomain

   _thisDomain="$1"

   get_domain_snapshots "$_thisDomain" || return 1

   check_domain_snapshots "$_thisDomain" || return 1

   if (( _FLAG_DOMAIN_HAS_TEMP != 0 )); then
      delete_temp_snapshot "$_thisDomain" || return 1
   fi

   check_domain_backup_mode "$_thisDomain"

   check_domain_compatibility "$_thisDomain"

   if (( _FLAG_DOMAIN_HAS_BITMAP == 0 )) && (( _FLAG_DOMAIN_HAS_MANUAL == 0 )); then
      do_diff "$_thisDomain" || return 1
   fi

   return 0
}

function do_backup () {
   local _thisDomain
   local _ret
   local _msg
   local i
   local _flagDidTempSnapshot
   local _flagDidSuspend

   _thisDomain="$1"
   _ret=0

   # if stop switch = 0 or if stop switch = 0 AND archive switch = 1 (= if anything less than stop mode)
   if (( _FLAG_STOP_SWITCH == 0 )) || (( _FLAG_ARCHIVE_SWITCH == 1 )); then

      _flagDidTempSnapshot=0

      # If this Domain NOT has Bitmap then do temp snapshot to freeze all disks before syncing
      if (( _FLAG_DOMAIN_HAS_BITMAP == 0 )); then
         create_snapshot "$_thisDomain" SnapBakTemp
         _ret=$?

         if (( _ret == 0 )); then
            _msg="Domain: [$_thisDomain] - SnapBakTemp snapshot created before syncing files"
            log_message d "$_msg"
            _flagDidTempSnapshot=1
         else
            _msg="Domain: [$_thisDomain] - Could not create SnapBakTemp snapshot - Domain will be paused while syncing live block devices"
            log_message w "$_msg"
         fi
      fi

      # Sync Files to Backup Directory
      _msg="Domain: [$_thisDomain] - Syncing files to Backup Directory (if newer)"
      log_message i "$_msg"

      # For each File
      for (( i=0; i<${#_ARR_FILE[@]}; i++ )); do

         _FLAG_THIS_DOMAIN_RUNNING=0

         # Get Domain State
         get_domain_state "$_thisDomain" || return 1

         _flagDidSuspend=0

         # If this Domain is running AND Did Temp Snapshot = 0 AND this File = Block Device then suspend
         if (( _FLAG_THIS_DOMAIN_RUNNING == 1 )) && (( _flagDidTempSnapshot == 0 )) && (( _ARR_FILE_FLAG_IS_BLOCK_DEVICE[i] == 1 )); then
            suspend_domain "$_thisDomain" || return 1
            _flagDidSuspend=1
            _msg="Domain: [$_thisDomain] - Domain paused while syncing live block device"
            log_message w "$_msg"
         fi

         # Sync file if newer
         sync_file_to_backup_if_newer "$_thisDomain" "$i" || return 1

         # If did suspend then resume
         if (( _flagDidSuspend == 1 )); then
            resume_domain "$_thisDomain" || return 1
            _msg="Domain: [$_thisDomain] - Domain unpaused"
            log_message d "$_msg"
         fi

      done

      # If did temp snapshot then delete
      if (( _flagDidTempSnapshot == 1 )); then
         delete_snapshot "$_thisDomain" SnapBakTemp || return 1
         _msg="Domain: [$_thisDomain] - SnapBakTemp snapshot deleted after syncing files"
         log_message d "$_msg"
      fi
   fi

   return 0
}

function do_rebase () {
   local _thisDomain
   local i
   local _msg

   _thisDomain="$1"

   # Rebase Backing Files if copy switch = 1 OR archive switch = 1
   if (( _FLAG_COPY_SWITCH == 1 )) || (( _FLAG_ARCHIVE_SWITCH == 1 )); then
      # For each File
      for (( i=0; i<${#_ARR_FILE[@]}; i++ )); do
         # If hasBackingFile=1 then rebase Backup
         if (( _ARR_FILE_FLAG_HAS_BACKING_FILE[i] == 1 )); then
            _msg="Domain: [$_thisDomain] - Rebasing standalone backup file"
            log_message i "$_msg"
            rebase_backup_backing_file "$_thisDomain" "$i" || return 1
         fi
      done
   fi

   return 0
}

function do_cleanup () {
   local _thisDomain
   local _msg

   _thisDomain="$1"

   _msg="Domain: [$_thisDomain] - Cleaning up Backup Directory"
   log_message v "$_msg"

   get_cleanup_paths

   # Prune Diff History if copy switch = 0 AND consolidate switch = 0 (mode = diff)
   if (( _FLAG_COPY_SWITCH == 0 )) && (( _FLAG_CONSOLIDATE_SWITCH == 0 )); then
      # Prune Diff History if MaxDiffHistory <> 0
      if (( _MAX_DIFFS != 0 )); then
         prune_diff_history_dir "$_thisDomain" || return 1
      fi
   # Otherwise delete Diff History
   else
      delete_diff_history_dir "$_thisDomain" || return 1
   fi

   delete_orphan_files_in_backup_dir "$_thisDomain" || _FLAG_ERROR=1

   return 0
}

function do_domain () {
   local _thisDomain
   local _msg

   _thisDomain="$1"

   # Test
   # unlock_domain "$_thisDomain"

   lock_domain "$_thisDomain" || return 1

   set_domain_backup_mode_switches

   _msg="Domain: [$_thisDomain] - Examining storage files"
   log_message v "$_msg"

   get_domain_storage "$_thisDomain" || return 1

   _msg="Domain: [$_thisDomain] - Examining snapshots"
   log_message v "$_msg"

   do_snapshots "$_thisDomain" || skip_snapshots "$_thisDomain"

   _msg="Domain: [$_thisDomain] - Re-examining storage files"
   log_message v "$_msg"

   get_domain_storage "$_thisDomain" || return 1

   do_backup "$_thisDomain" || return 1

   do_rebase "$_thisDomain" || return 1

   do_cleanup "$_thisDomain" || _FLAG_ERROR=1

   return 0
}

# Main block

parse_options "$@" || exit 1

validate_options || exit 1

check_permissions_on_backup_dir || exit 1

set_log_dir

check_dependencies || exit 1

_mainTimeStamp="$(date "+%Y%m%d-%H%M%S")"

echo "$_mainTimeStamp [INF] Selected options: [$_SELECTED_OPTIONS]" >> "$_LOG_FILE"

# Get all Domains if All Domains or All Non Running option set
if (( _FLAG_ALL_DOMAINS != 0 )) || (( _FLAG_ALL_NON_RUNNING != 0 )); then
   get_all_domains || exit 1
fi

check_domains_not_empty || exit 1

# Remove excluded Domains if requested
if (( ${#_ARR_EXCLUSION[*]} != 0 )); then
   remove_excluded_domains
fi

check_domains_not_empty || exit 1

list_domains

_FLAG_ERROR=0

_mainMsg="Started process in [$_BACKUP_MODE] mode"
log_message i "$_mainMsg"

# For each Domain
for _mainDomain in "${_ARR_DOMAIN[@]}"; do

   do_domain "$_mainDomain" || skip_domain "$_mainDomain"

   unlock_domain "$_mainDomain"

done

if (( _FLAG_ERROR == 0 )); then
   _mainMsg="Completed process in [$_BACKUP_MODE] mode"
   log_message i "$_mainMsg"
else
   _mainMsg="Completed process in [$_BACKUP_MODE] mode WITH ERRORS"
   log_message w "$_mainMsg"
   exit 1
fi

exit