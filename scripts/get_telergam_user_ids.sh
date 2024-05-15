#!/bin/zsh

# set script path, current user path and project root path
#  assuming no folder structure edited
ex_path=$(dirname "$0")
_pwd=$PWD
work_dir=$(cd "${ex_path}"/.. && pwd)

## exits script (for testing)
function stop() {
  cd ${_pwd}
  exit 0
}

# csvquote util (https://github.com/dbro/csvquote) is needed
#  in case of OSX installs it if not present or exits otherwise
if ! command -v csvquote &> /dev/null; then
  if [[ $OSTYPE == darwin* ]]; then
    echo -e "installing csvquote"
    brew install sschlesier/csvutils/csvquote
  else
    echo -e "csvquote needed. It can be found at https://github.com/dbro/csvquote"
    # exit
    return
  fi
fi

# cd to project root path
cd ${work_dir}

# set variables
file='sputnik.enc.env'
google_sheet_id=$(\sops -d --extract '["GOOGLE_SHEET_ID"]' ${file})
# get old ids
old=$(\sops -d --extract '["ALLOWED_TELEGRAM_USER_IDS"]' ${file})
users='users.csv'

# Downloads google spreadsheet in silent mode following requested url redirects to a local csv file
curl -sL "https://docs.google.com/spreadsheets/d/${google_sheet_id}/export?format=csv&gid=0" -o ${users}

# Get column number with telegram ID by searching for word "telegram" in table headers
column=$(csvheader ${users} | grep telegram | awk '{print $1}')

# Get comma separated list of telegram user ids from appropriate downloaded csv
#  tr -d '\r' - replaces DOS line breaks with normal ones
#  awk uses comma as filed separator (-F,)
#  prints third column (telegram IDs) from second line (suppresses table header)
#  and skips empty values
#  paste -sd "," - replaces new lines with comma
#csvquote ${users} | tr -d '\r' | awk -F, '(NR>1 && length($3)>0){print $3}' | sort | uniq | paste -sd "," - > ${ids}
ids=$(csvquote ${users} | tr -d '\r' | awk -v col="${column}" -F, '(NR>1 && length($col)>0){print $col}' | sort | uniq | paste -sd "," -)
#echo "${ids}"

# compare ids
old_array=(${(@s:,:)old})
new_array=(${(@s:,:)ids})
echo -e "==================\nUsers added:"
comm -13 <(echo $old_array | sort | tr ' ' '\n') <(echo $new_array | sort | tr ' ' '\n')
echo -e "==================\nUsers removed:"
comm -23 <(echo $old_array | sort | tr ' ' '\n') <(echo $new_array | sort | tr ' ' '\n')
echo

#stop

# Change ENV value for specified key in env file
#  for plain env
#sed -i '' "/^ALLOWED_TELEGRAM_USER_IDS=/s/=.*/=${ids}/" 1.env
#  for sops encrypted env
\sops --set "[\"ALLOWED_TELEGRAM_USER_IDS\"] \"${ids}\"" ${file}

# clean up
rm -f ${users}

## DOCKER
echo "=================="
#  use remote docker context with --context flag
context='cit-droplet'
name='sputnik_bot'

#version=$(docker --context=$context images ${name} --format "{{.Tag}}" | grep -v latest)

#  remove old container
docker --context ${context} rm -f ${name}
#  start container with new env
\sops exec-file --no-fifo ${file} "docker --context ${context} run -d -v /home/aamite/usage_logs:/app/usage_logs --env-file {} --restart=always --name=${name} ${name}"

#
docker --context ${context} ps -a
echo
docker --context ${context} logs ${name}
echo

# cd to initial user path
cd ${_pwd}


function demo() {
  emulate -L zsh
  zmodload zsh/zutil || return

  # Default option values can be specified as (value).
  local help verbose message file=(default)

  # Brace expansions are great for specifying short and long
  # option names without duplicating any information.
  zparseopts -D -F -K -- \
    {h,-help}=help       \
    {v,-verbose}=verbose \
    {f,-file}:=file || return
  # zparseopts prints an error message if it cannot parse
  # arguments, so we can simply return on error.

  if (( $#help )); then
    print -rC1 --      \
      "$0 [-h|--help]" \
      "$0 [-v|--verbose] [-f|--file=<file>] [<message...>]"
    return
  fi

  # Presence of options can be checked via (( $#option )).
  if (( $#verbose )); then
    print verbose
  fi

  # Values of options can be retrieved through $option[-1].
  print -r -- "file: ${(q+)file[-1]}"

  # Positional arguments are in $@.
  print -rC1 -- "message: "${(q+)^@}
}