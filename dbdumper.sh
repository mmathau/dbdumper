#!/bin/bash
#
# name: dbdumper
# version: 1.0.1
# license: GPL v3+
# bash script to dump mysql and postgres databases hosted in docker containers
# reading credentials and mount points from containers by using docker inspect
#
# this script assumes that your containers are created using a mount point
# named /backup where backups are to be stored, which can be mapped to any folder on the host.

set -o errexit  # abort on nonzero exitstatus
set -o nounset  # abort on unbound variable
set -o pipefail # dont hide errors within pipes

readonly DOCKER="/usr/bin/docker"
readonly CONTAINER_NAMES=("container1-db" "container2-db" "container3-db")

container_exists() {
    printf '%s' "$(${DOCKER} ps -q -f name="${1}")"
}

get_env_var() {
    # https://stackoverflow.com/a/39993106
    local result
    result=$(
        ${DOCKER} inspect --format \
            '{{range $value := .Config.Env}}{{println $value}}{{end}}' \
            "${1}" | grep "${2}"
    )
    printf '%s' "${result#*=}"
}

get_backup_path() {
    local backup_path
    backup_path=$(
        ${DOCKER} inspect --format \
            '{{range .Mounts}}{{if eq .Destination "/backup"}}{{.Source}}{{end}}{{end}}' \
            "${1}"
    )
    printf '%s' "${backup_path}"
}

get_database_type() {
    #TODO: find a better way to determine database type
    local mysql_password
    local postgres_user
    local postgres_password

    mysql_password=$(get_env_var "${1}" "MYSQL_ROOT_PASSWORD")
    postgres_user=$(get_env_var "${1}" "POSTGRES_USER")
    postgres_password=$(get_env_var "${1}" "POSTGRES_PASSWORD")

    if [[ -n ${mysql_password} ]]; then
        printf "mysql"
    elif [[ -n ${postgres_user} && -n ${postgres_password} ]]; then
        printf "postgres"
    else
        return 1
    fi
}

dump_database() {
    local container="${1}"
    local dbtype="${2}"
    local username="${3:-username}"
    local password="${4:-password}"
    local output="${5:-output.sql}"

    local cmd
    case "${dbtype}" in
    mysql)
        cmd="mysqldump -u ${username} --password=${password} --all-databases -r /backup/${output}"
        ;;
    postgres)
        cmd="pg_dumpall -c --dbname=postgres://${username}:${password}@localhost -f /backup/${output}"
        ;;
    *)
        printf "ERROR: invalid database type!\n" 1>&2
        return 1
        ;;
    esac

    # https://stackoverflow.com/a/41080205
    $DOCKER exec --tty "${container}" sh -c "$cmd; exit $?"

    if [[ $? -eq 0 ]]; then
        printf "created backup '%s'\n" "${output}"
        return 0
    else
        printf "ERROR: failed to create backup '%s'\n" "${output}" 1>&2
        return 1
    fi
}

dump_container_database() {
    local container_name="${1}"
    local backup_path="${2}"

    local db_type
    local username
    local password
    local backup_name

    db_type=$(get_database_type "${container_name}")
    backup_name="${container_name}_$(date +%Y%m%d%H%M%S).sql"
    case "${db_type}" in
    mysql)
        username="root"
        password=$(get_env_var "${container_name}" "MYSQL_ROOT_PASSWORD")
        ;;
    postgres)
        username=$(get_env_var "${container_name}" "POSTGRES_USER")
        password=$(get_env_var "${container_name}" "POSTGRES_PASSWORD")
        ;;
    *)
        printf "ERROR: couldnt determine database type for container '%s'\n" "${container_name}" 1>&2
        return 1
        ;;
    esac

    dump_database "${container_name}" "${db_type}" "${username}" "${password}" "${backup_name}"
    if [[ -e "${backup_path}/${backup_name}" ]]; then
        chmod 600 "${backup_path}/${backup_name}"
    fi
}

rotate_backups() {
    # Delete backups older than 14 days
    mapfile -t results < <(find "${1}" -maxdepth 1 -type f -name '*.sql' -mtime +14 -print -delete)

    if ((${#results[@]})); then
        printf "rotated backup '%s'\n" "${results[@]##*/}"
    else
        printf "no backups to rotate\n"
    fi
}

main() {
    if [[ "$EUID" -ne 0 ]]; then
        printf "FATAL ERROR: need to run as root!\n" 1>&2
        exit 1
    fi

    if [[ ! -x $(command -v ${DOCKER}) ]]; then
        printf "FATAL ERROR: docker engine not found!\n" 1>&2
        exit 1
    fi

    for container in "${CONTAINER_NAMES[@]}"; do
        local backup_path

        if [[ ! $(container_exists "${container}") ]]; then
            printf "ERROR: cant find container '%s'!\n" "${container}" 1>&2
            continue
        fi
        printf "found container '%s'\n" "${container}"

        printf "dumping container '%s' database\n" "${container}"
        backup_path=$(get_backup_path "${container}")
        if [[ -z ${backup_path} ]]; then
            printf "ERROR: couldnt find mountpoint '/backup' for container '%s'\n" "${container}" 1>&2
            continue
        fi
        dump_container_database "${container}" "${backup_path}"

        printf "rotating backups\n"
        rotate_backups "${backup_path}"

        printf "\n"
    done
}

start_time=$(date +%s%N)
readonly start_time

printf "starting ${0##*/} on %(%Y-%d-%m %H:%M:%S)T\n\n" -1

main

run_time=$(($(date +%s%N) - start_time))
readonly run_time

printf "finished in %s ms\n" "$((run_time / 1000000))"
exit 0
