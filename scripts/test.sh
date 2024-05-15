#!/bin/zsh
# preferably script should be executed with sops exec-env ${enc_env_file} './script args'

# Read script arguments and options
local flag_help
local flag_dry
local arg_source=(yandex)
local arg_build=(skip)  # default is to skip building new image
local usage=(
  "## USAGE\n"
  "[-h|--help]\tshow this message"
  "[-d|--dry_run]\tdry run script with outputs"
  "[-f|--file]\tsource file with list of users [yandex, google]"
  "[-b|--build]\tforce build new image with bumping tag [major, minor, patch]"
  "            \tskip building new docker image if missing or not specified"
)

zparseopts -D -F -K -- \
  {h,\?,-help}=flag_help \
  {d,-dry_run}=flag_dry \
  {s,-skip_build}=flag_skip \
  {f,-file}:=arg_source \
  {b,-build}:=arg_build ||
  return

[[ "${flag_help}" ]] && print -l "${usage[@]}" && return

if [[ ${arg_source[-1]} == [yYgG]* ]]; then
  provider=${arg_source[-1]::1}
else
  echo "## WARN: Unknown user list provider '${arg_source[-1]}', using 'yandex'"
  provider="y"
fi

if [[ ${arg_build[-1]} =~ (major|minor|patch|skip) ]]; then
  bump_arg=${arg_build[-1]}
else
  echo "## WARN: Unknown Semver Bumb arg '${arg_build[-1]}', using 'patch'"; bump_arg="patch"
fi

stop() {
  # exits script and return exit code (for testing)
  exit "${1-0}"
}

check_utils() {
  # Sets "git root"
  git config --list | grep alias.root &> /dev/null
  if [[ $? != 0 ]]; then
    git config --global alias.root "rev-parse --show-toplevel"
  else
    [[ "${flag_dry}" ]] && echo -e "## DRY: git root alias is set"
  fi
  # csvquote util (https://github.com/dbro/csvquote) is needed
  #  in case of OSX installs it if not present or exits otherwise
  if ! command -v csvquote &> /dev/null; then
    if [[ $OSTYPE == darwin* ]]; then
      echo -e "installing csvquote"
      brew install sschlesier/csvutils/csvquote
    else
      echo -e "csvquote needed. It can be found at https://github.com/dbro/csvquote"
      stop 1
    fi
  else
    [[ "${flag_dry}" ]] && echo -e "## DRY: csvquote util is installed"
  fi
  # ssconvert util is needed
  #  in case of OSX installs it if not present or exits otherwise
  if ! command -v ssconvert &> /dev/null; then
		if [[ $OSTYPE == darwin* ]]; then
      echo -e "installing ssconvert"
      brew install gnumeric
    else
      echo -e "ssconvert not found. It can be found in gnumeric util"
      stop 1
    fi
  else
    [[ "${flag_dry}" ]] && echo -e "## DRY: ssconvert util is installed"
	fi
	# semver util (https://github.com/fsaintjacques/semver-tool) is needed
	#  in case of OSX installs it if not present or exits otherwise
  if ! command -v semver &> /dev/null; then
    if [[ $OSTYPE == darwin* ]]; then
      echo -e "installing semver"
      wget -O /usr/local/bin/semver https://raw.githubusercontent.com/fsaintjacques/semver-tool/master/src/semver &> /dev/null
      chmod +x /usr/local/bin/semver
      semver --version
    else
      echo -e "semver needed. It can be found at https://github.com/fsaintjacques/semver-tool"
      stop 1
    fi
  else
    [[ "${flag_dry}" ]] && echo -e "## DRY: semver util is installed"
  fi
}

set_envs() {
  # set variables
  env_file="sputnik.enc.env"
  users="${work_dir}/users.csv"
  # set docker context, image name and current image version
  context='cit-droplet'
  name='sputnik_bot'
  IMAGE_ID=$(docker --context=${context} images ${name}:latest --format "{{.ID}}")
  IMAGE_NAME=$(docker --context=${context} image inspect "${IMAGE_ID}" | jq -r '.[].RepoTags[] | select( test("latest")|not )')
  cur_tag=${IMAGE_NAME##*:}
  # set source of users list
  case ${1} in
    [g]) # Google
      if [[ ! -v GOOGLE_SHEET_ID ]]; then
        GOOGLE_SHEET_ID=$(\sops -d --extract '["GOOGLE_SHEET_ID"]' ${env_file})
      fi
      base_url="https://docs.google.com/spreadsheets/d/${GOOGLE_SHEET_ID}/export"
      # "https://docs.google.com/spreadsheets/d/${GOOGLE_SHEET_ID}/export?format=csv&gid=0"
      download_url="${base_url}?format=csv&gid=0"
      ;;
    *) # Yandex
      base_url="https://cloud-api.yandex.net/v1/disk/resources/download"
      ya_disk_file="TEST_ChatGPTBot_Users.xlsx"
      ya_disk_path="/Service/${ya_disk_file}"
      _path=$(echo -n ${ya_disk_path} | jq -sRr @uri)
      req_url="${base_url}?path=${_path}"
      c_header="Accept: application/json"
      if [[ ! -v YA_TOKEN ]]; then
        YA_TOKEN=$(\sops -d --extract '["YA_TOKEN"]' ${env_file})
      fi
      a_header="Authorization: OAuth ${YA_TOKEN}"
      download_url=$(curl -sX GET --header ${c_header} --header ${a_header} ${req_url} | jq -r '.href')
      ;;
  esac
  # Get current telegram user ids
  if [[ ! -v ALLOWED_TELEGRAM_USER_IDS ]]; then
    ALLOWED_TELEGRAM_USER_IDS=$(\sops -d --extract '["ALLOWED_TELEGRAM_USER_IDS"]' ${env_file})
  fi
  old=${ALLOWED_TELEGRAM_USER_IDS}
}

get_new_ids() {
  case ${1} in
    [g])
      echo -e "## INFO: Using Google docs"
      curl -sL "${download_url}" -o "${users}"
      ;;
    *)
      echo -e "## INFO: Using Yandex docs"
      curl -sL "${download_url}" -o "${users}"
      ssconvert "${users}" "${users}"
      ;;
  esac
  column=$(csvheader "${users}" | grep telegram | awk '{print $1}')
  # shellcheck disable=SC2086
  ids=$(csvquote ${users} | tr -d '\r' | awk -v col="${column}" -F, '(NR>1 && length($col)>0){print $col}' | sort | uniq | paste -sd "," -)
}

compare_ids() {
  # compare ids
  old_array=(${(@s:,:)old})
  new_array=(${(@s:,:)ids})
  echo -e "## INFO: Users diff\n==================\nUsers added:"
  comm -13 <(echo $old_array | sort | tr ' ' '\n') <(echo $new_array | sort | tr ' ' '\n')
  echo -e "------------------\nUsers removed:"
  comm -23 <(echo $old_array | sort | tr ' ' '\n') <(echo $new_array | sort | tr ' ' '\n')
  echo -e "=================="
}

cleanup() {
  # clean up
  rm -f "${users}"
}

docker_build() {
  if [[ "${1}" == "skip" && ! "${flag_dry}" ]]; then
    echo -n "## INFO: Skip building docker image\n"
    return
  fi
  echo -e "## INFO: Bumping docker tag version (${1})"
  if [[ "${flag_dry}" ]]; then
    new_tag=${cur_tag}
  else
    new_tag=$(semver bump ${1} ${cur_tag})
  fi
  echo -e "${cur_tag} --> ${new_tag}"
  echo -e "## INFO: Building new docker image ${name}:${new_tag}"
  if [[ "${flag_dry}" ]]; then
    echo -e "## DRY: docker --context=${context} build --no-cache -t ${name}:${new_tag} -t ${name} ."
    return
  fi
  docker --context=${context} build --no-cache -t ${name}:${new_tag} -t ${name} .
}


edit_env_file() {
  # Change ENV value for specified key in sops encrypted env file
  if [[ "${flag_dry}" ]]; then
    echo -e "## DRY: Updating ${env_file}"
    return
  fi
  echo -e "## INFO: Updating ${env_file}"
  \sops --set "[\"ALLOWED_TELEGRAM_USER_IDS\"] \"${ids}\"" ${env_file}
}

docker_run() {
  if [[ "${flag_dry}" ]]; then
    echo -e "## DRY: Restarting docker container with new ${env_file}"
    return
  fi
  echo -e "## INFO: removing old container"
  docker --context ${context} rm -f ${name}
  echo -e "## INFO: starting new container"
  \sops exec-file --no-fifo ${env_file} "docker --context ${context} run -d -v /home/aamite/usage_logs:/app/usage_logs --env-file {} --restart=always --name=${name} ${name}"
  echo -e "## INFO: docker processes status"
  docker --context ${context} ps -a
  echo -e "## INFO: docker container log"
  docker --context ${context} logs ${name}
  echo
}

work_dir=$(git root)
check_utils
set_envs ${provider}
get_new_ids ${provider}
compare_ids
cleanup
docker_build ${bump_arg}
edit_env_file
docker_run
#stop

