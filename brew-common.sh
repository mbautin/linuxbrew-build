#@IgnoreInspection BashAddShebang

# Copyright (c) YugaByte, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.  You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License
# is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
# or implied.  See the License for the specific language governing permissions and limitations
# under the License.
#

set -euo pipefail

if [[ $BASH_SOURCE == $0 ]]; then
  echo "$BASH_SOURCE must be sourced, not executed" >&2
  exit 1
fi

# -------------------------------------------------------------------------------------------------
# Constants
# -------------------------------------------------------------------------------------------------

declare -i -r ABS_PATH_LIMIT=85

if [[ $OSTYPE == linux* ]]; then
  readonly YB_BREW_TYPE_LOWERCASE=linuxbrew
  readonly YB_BREW_TYPE_CAPITALIZED=Linuxbrew
  readonly YB_OS_FAMILY=linux
elif [[ $OSTYPE == darwin* ]]; then
  readonly YB_BREW_TYPE_LOWERCASE=homebrew
  readonly YB_BREW_TYPE_CAPITALIZED=Homebrew
  readonly YB_OS_FAMILY=macos

  function sha256sum() {
    shasum -a 256 "$@"
  }
else
  echo >&2 "Unknown OS type: $OSTYPE"
  exit 1
fi

# -------------------------------------------------------------------------------------------------
# Functions
# -------------------------------------------------------------------------------------------------

log() {
  echo >&2 "[$( date +%Y-%m-%dT%H:%M:%S )] $*"
}

fatal() {
  log "$@"
  exit 1
}

separator() {
  echo >&2 "--------------------------------------------------------------------------------------"
}

thick_separator() {
  echo >&2 "======================================================================================"
}

separator_with_spacing() {
  echo >&2
  separator
  echo >&2
}

heading() {
  echo >&2
  separator
  echo >&2 "$*"
  separator
  echo >&2
}

big_heading() {
  echo >&2
  thick_separator
  echo >&2 "$*"
  thick_separator
  echo >&2
}

create_symlink() {
  if [[ $OSTYPE == linux* ]]; then
    # -s - symbolic link
    # -f - remove existing destination files
    # -T (--no-target-directory) - treat LINK_NAME as a normal file always
    ln -sfT "$@"
  else
    ln -sf "$@"
  fi
}

run_tar() {
  if [[ $OSTYPE == linux* ]]; then
    ( set -x; tar "$@" )
  else
    if which -s gtar; then
      ( set -x; gtar "$@" )
    elif [[ -n ${BREW_HOME:-} && -f $BREW_HOME/bin/gtar ]]; then
      ( set -x; "$BREW_HOME/bin/gtar" "$@" )
    else
      fatal "Could not find gtar"
    fi
  fi
}

set_brew_timestamp() {
  if [[ -z ${YB_BREW_TIMESTAMP:-} ]]; then
    export YB_BREW_TIMESTAMP=$(date +%Y%m%dT%H%M%S)
  fi
}

if [[ $OSTYPE == darwin* ]] && ! which -s realpath; then
  realpath() {
    python -c "import sys, os; sys.stdout.write(os.path.realpath(sys.argv[1]))" "$@"
  }
fi

# Returns the prefix for a new Homebrew/Linuxbrew installation path, based on the current directory,
# YB_BREW_TYPE ("homebrew" or "linuxbrew") and YB_BREW_TIMESTAMP (which would be set on demand).
# The return value is placed in the brew_path_prefix variable in the parent scope.
get_brew_path_prefix() {
  set_brew_timestamp
  brew_path_prefix="$(realpath .)/$YB_BREW_TYPE_LOWERCASE-$YB_BREW_TIMESTAMP"
  if [[ -n ${YB_BREW_SUFFIX:-} ]]; then
    brew_path_prefix+="-$YB_BREW_SUFFIX"
  fi
  local len=${#brew_path_prefix}
  if [[ $len -gt $ABS_PATH_LIMIT ]]; then
    fatal "Homebrew/Linuxbrew absolute path should be no more than $ABS_PATH_LIMIT bytes, but " \
          "actual length is $len bytes: $brew_path_prefix"
  fi
}

# Extends the given path so that it has a fixed length.
# Parameters:
#   path - source path.
#   len - required output path length. Optional parameter, if absent uses $ABS_PATH_LIMIT.
#   git_sha1 - use this Git SHA1 for the filler part of the path.
#
# Return value: the variable fixed_length_path in the parent scope.
get_fixed_length_path() {
  local path=$1
  local len=${2:-$ABS_PATH_LIMIT}
  local sha1=${3:-}

  # Use the Git SHA1 of the Homebrew repository as a filler.
  if [[ -z $sha1 ]]; then
    if [[ -f $path/GIT_SHA1 ]]; then
      sha1=$( cat $path/GIT_SHA1 )
    else
      if [[ ! -d $path/.git ]]; then
        fatal "Directory '$path' is not a Git repository, cannot get SHA1"
      fi
      sha1=$( cd "$path" && git rev-parse HEAD )
    fi
  fi
  if [[ ! $sha1 =~ ^[0-9a-f]{40}$ ]]; then
    fatal "Invalid Git SHA1: '$sha1', expected 40 hex characters"
  fi

  fixed_length_path=\
"$path-${sha1}xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  fixed_length_path=${fixed_length_path:0:$len}
}

# Escape special characters in source string, so it can be used with sed as simple string pattern.
# https://stackoverflow.com/a/28783790/461529
# https://stackoverflow.com/a/29613573/461529
get_escaped_sed_re() {
  # Every character except ^ is placed in its own character set [...] expression to treat it as a
  # literal. Then, ^ characters are escaped as \^. Note, that []] also works, i.e. matches ]
  # correctly.
  sed 's/[^^]/[&]/g; s/\^/\\^/g' <<<$1
}

# Escape special characters in source string, so it can be used with sed as a replacement string.
# https://stackoverflow.com/a/28783790/461529
# https://stackoverflow.com/a/29613573/461529
get_escaped_sed_replacement_str() {
  # The replacement string in a sed s/// command is not a regex, but it recognizes placeholders
  # that refer to either the entire string matched by the regex (&) or specific capture-group
  # results by index (\1, \2, ...), so these must be escaped, along with the (customary) regex
  # delimiter, /.
  local delim=${2:-/}
  sed "s/[$delim&\]/\\\\&/g" <<<$1
}
