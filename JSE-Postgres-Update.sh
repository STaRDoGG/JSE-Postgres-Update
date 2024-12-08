#!/bin/bash

# + ----------------------------------------------------------------------------------------------------------------- +
# |                                                                                                                   |
# | POSTGRES DATA FILES UPDATE: J. Scott Elblein                                                               WIP    |
# |                                                                                                                   |
# | USAGE                                                                                                             |
# |   - First, edit the options below to match your setup, and then                                                   |
# |   - sudo ./JSE-Postgres-Update.sh                                                                                 |
# |                                                                                                                   |
# | DESC                                                                                                              |
# |   - Script to fix the error (i.e.):                                                                               |
# |     "The data directory was initialized by PostgreSQL version 16, which is not compatible with this version 17"   |
# |   - Backs up the current (a.k.a. 'old') data + server settings, then updates them to the 'new' stuff.             |
# |                                                                                                                   |
# | REFS                                                                                                              |
# |   - https://stackoverflow.com/a/78782530/553663                                                                   |
# |   - https://www.postgresql.org/docs/current/pgupgrade.html                                                        |
# |   - https://geekdrop.com/content/myspace-symbol-codes-character-codes                                             |
# |                                                                                                                   |
# | TODO                                                                                                              |
# |   - In the case of failure notices; add in troubleshooting suggestions to all of them.                            |
# |                                                                                                                   |
# | ENHANCEMENTS                                                                                                      |
# |   - This script COULD just be used to do backups if wanted, w/some added tweaks. i.e. cline args, etc.            |
# |   - Add user choice between the old fashioned way (back/rest the data), or just use pg_dumpall/pg_upgrade.        |
# |                                                                                                                   |
# + ----------------------------------------------------------------------------------------------------------------- +

# + ===================================================================================================== DB SETTINGS +

# Postgres User
pgs_user="root"

# Postgres password
pgs_pw=''

# Database
pgs_db="postgres"

# Network (i.e. Docker network the PGS server is in)
pgs_net="db-postgres"

# + ================================================================================================== OPTIONS (EDIT) +

# Clear screen first? (1=yes)
cls="1"

# Upgrade method (0 = manual method; anything else = pg_dumpall method) (TODO: may abandon this idea)
upgrd_method="1"

# Show debug stuff (logs, etc.) (0 = no; 1 = yes)
show_dbg="0"

# Timestamp Format
tstamp=$(date +"%Y%m%d_%H%M%S")

# PGS Server Versions. The same way you'd add it to your Compose, minus the colon. (i.e. 16.4 or latest))
pgs_oldver="16.4"
pgs_newver="latest"

# Backup Prefix
bak_prefix="PGS-v${pgs_oldver}-bak-"

# Paths/volumes/mounts
data_vol="/opt/docker/configs/postgres/data:/var/lib/postgresql/data:rw" # (full mount) Your data files
bak_vol="/mnt/e/Docker/Shared-Storage:/Shared-Storage:rw"                # (full mount) Dir for backups

# Temp Postgres container name
pgs_tmp="pgs-tmp"

# Max retries waiting for container to be available. Will auto-abort when reached.
max_retries=10

# Interval to sleep (wait) between retries
sleep_int=2

# Minimum DB backup file size in kilobytes. You'll want to do a manual backup first to get an idea of size to set.
bak_db_minsize=1500

# Save all backed up stuff to a compressed tar.gz/tar.bz2? (0 = leave uncompressed; 1 = gzip; 2 = bz2)
compress=2

# For the container version of Postgres, when the Data directory doesn't exist it'll automatically create it
# itself. Therefore technically we shouldn't have to do it in this script; simply deleting it will allow the
# container to auto-create it and populate it with everything based upon our SQL import.
# Default is 0, which if it already exists (which it probably does) will just empty what's in it, and verify
# it's user and permissions. If any of those are incorrect it'll try to set them correctly. If it doesn't exist
# will create the directory and then validate those same things.
# Setting it to a non-zero will simply entirely delete the existing directory and let the container make it all.
just_delete_data_dir=0

# The final resting place of the completed backup file. If empty, defaults to local_bak_path,
# which is the local path in bak_vol.
final_destination=""

# Show disclaimer? (0 = no; else = yes)
disclaimer=1

# Play a ding when script completes? (0 = no; else = yes)
ding=1

# *Holding out tin cup*
help_a_brother_out="https://buymeacoffee.com/stardogg"

# + ============================================================================================= GLOBALS (DONT EDIT) +

script_ver="1.0"
script_title="J. SCOTT ELBLEIN'S POSTGRES UPGRADE SCRIPT:"

tmp_prefix="/tmp/jse-psql-update"

# Console colors (yellow (bold), red (bold), green (bold), cyan (bold), purple (bold), reset)
# Note: \e[1;38m doesn't exist, so changed to purple
# Ref: https://gist.github.com/JBlond/2fea43a3049b38287e5e9cefc87b2124
ylw="\e[1;33m"
red="\e[1;31m"
grn="\e[1;32m"
cyn="\e[1;36m"
prp="\e[1;35m"
rst="\e[0m"

bak_name=${bak_prefix}${tstamp}                                            # Append everything

local_data_path=$(echo -e "${data_vol}" | cut -d':' -f1)                   # Parse out the LOCAL DATA path
local_data_path_full="${local_data_path}-${bak_name}"                      # Local data path w/timestamp

container_bak_path=$(echo -e "${bak_vol}" | cut -d':' -f2)                 # Parse out the CONTAINER'S DB BACKUP path
container_bak_path_full="${container_bak_path}/${bak_name}.sql"            # Container DB Backup path w/timestamp

local_bak_path=$(echo -e "${bak_vol}" | cut -d':' -f1)                     # Parse out the LOCAL DB BACKUP path
local_bak_path_full="${local_bak_path}/${bak_name}.sql"                    # Local DB backup path w/timestamp

# Extract only the backed-up dir name
#base_name=$(basename "$local_data_path_full")
parent=$(dirname "$local_data_path")                                       # Parent of data dir
tmp_path="/tmp/${bak_name}.tar"                                            # Working dir for tar

exit_msg="Exiting WHOLE mf'n script."

# Add some defaults if user flubbed up and left them empty. They may still not work, but better than nothing.
pgs_tmp=${pgs_tmp:-"pgs-tmp"}
pgs_user=${pgs_user:-"root"}
pgs_db=${pgs_db:-"postgres"}
pgs_net=${pgs_net:-"bridge"}
pgs_newver=${pgs_newver:-"latest"}
tstamp=${tstamp:-$(date +"%Y%m%d_%H%M%S")}
bak_prefix=${bak_prefix:-"PGS-v${pgs_oldver}-bak-"}
max_retries=${max_retries:-10}
sleep_int=${sleep_int:-2}
bak_db_minsize=${bak_db_minsize:-1}
final_destination=${final_destination:-${local_bak_path}}

# * DANGER! KRAYT DRAGONS! *
# Unless you know exactly what you're doing; I highly recommend NOT changing this. Specifically, because the script
# does a forced silent deletion of this tmp dir when cleaning up, and if you accidentally fill in a wrong path that
# contains stuff you don't want deleted, they'll be deleted. Seriously, it's just best to leave it as is.
tmp_prefix=${tmp_prefix:-"/tmp/jse-psql-update"}

# + ======================================================================================================= FUNCTIONS +

# + Generic Funcs --------------------------------------------------------------------------------------------------- +

chars() {
    # Returns a string of x number of the character passed to it
    # I pretty much only use this when there are MANY repeated chars/spaces. I don't when just a few.

    if [[ -z "$1" ]] || [[ -z "$2" ]]; then
        echo "Error: Both a character and a number are required."
        echo "Example usage: chars '*' 5"
        return 1
    fi

    local char=$1
    local num_times=$2

    if [[ "$char" = " " ]]; then
        # Handle spaces separately to avoid collapsing
        printf "%${num_times}s" ""
    else
        # Print repeated characters
        printf "%.0s$char" $(seq 1 "$num_times")
    fi
}

# + ----------------------------------------------------------------------------------------------------------------- +

# Separators
# Note: These would've been w/the other var declarations above, but use chars(), so they're here.
sep_full="★ $(chars "-" 116) ★"

# Debug versions
dbg_bar_top="${cyn}╔═${rst} ${prp}DEBUG${rst} ${cyn}$(chars "═" 110)╗${rst}"
dbg_bar_btm="${cyn}╚$(chars "═" 118)╝${rst}"
dbg_pointer="${cyn}╟${rst}"
dbg_vert="${cyn}║${rst}"

# Disclaimer versions
fncy_bar_top="${red}╔═${rst} ${ylw}DISCLAIMER${rst} ${red}$(chars "═" 105)╗${rst}"
fncy_bar_btm="${red}╚$(chars "═" 118)╝${rst}"
#fncy_pointer="${red}╟${rst}"
fncy_vert="${red}║${rst}"

# + ----------------------------------------------------------------------------------------------------------------- +

rotating_cursor() {
    local pid=$1
    local delay=0.1
    local spin_chars='|/-\'

    while kill -0 "$pid" 2>/dev/null; do
        for char in $(echo "$spin_chars" | fold -w1); do
            printf "\r%s" "$char"
            sleep "$delay"
        done
    done
    printf "\r"  # Clear the line after done
}

# + ----------------------------------------------------------------------------------------------------------------- +

log() {
    # Echos the string to the terminal as usual, but also strips ANSI color codes and then writes the string to a
    # log file.
    # $1 is the string passed to the function

    # Tests the .log exists; if not creates it (and parent dir if also needed)
    # A tiny bit more cpu than needed, checking these each time the func is called; I could've just added it once
    # to the startup, but wanted it in a single "neat" place.
    [[ -f "${tmp_prefix}/logs/upgrade.log" ]] || { mkdir -p "${tmp_prefix}/logs"; touch "${tmp_prefix}/logs/upgrade.log"; }

    echo -e "$1" | tee >(sed -E 's/\x1B\[[0-9;]*m//g' >> "${tmp_prefix}/logs/upgrade.log")
}

# + ----------------------------------------------------------------------------------------------------------------- +

danger_will_robinson() {
    # Not *really* that dangerous since we're backing up first, but best to still alert & give chance to bail out.

    log "\n${fncy_bar_top}"
    log "${fncy_vert}$(chars " " 118)${red}║${rst}"
    log "${fncy_vert} Though this script makes every effort to back everything up and validate those backups before doing anything that$(chars " " 4)${red}║${rst}"
    log "${fncy_vert} could potentially result in any data loss, the onus to proceed is all on you.$(chars " " 40)${red}║${rst}"
    log "${fncy_vert}$(chars " " 118)${red}║${rst}"
    log "${fncy_vert} I'm not responsible for anything: at all, whatsoever, zero, zilch, nada, numero 0, by your use of this script.$(chars " " 7)${red}║${rst}"
    log "${fncy_vert}$(chars " " 118)${red}║${rst}"
    log "${fncy_vert} That said, don't let it scare you off; it's all pretty simple stuff here; we just backup your databases and your     ${red}║${rst}"
    log "${fncy_vert} data directory, then restore them after.$(chars " " 77)${red}║${rst}"
    log "${fncy_vert}$(chars " " 118)${red}║${rst}"
    log "${fncy_vert} But since there's a minuscule chance that something could happen, a standard disclaimer is warranted.$(chars " " 16)${red}║${rst}"
    log "${fncy_vert}$(chars " " 118)${red}║${rst}"
    log "${fncy_bar_btm}\n"

    while true; do
        log "${grn}Your call! Shall we proceed?${rst} Press ${grn}Y${rst} for Yes, or ${red}N${rst} to exit: "
        read -r choice
        case "$choice" in
            [Yy])
                log "\n${grn}Good call! I like your spunk.${rst}\n"
                sleep 1
                break
                ;;
            [Nn])
                log "\n${ylw}Chicken! We out ...${rst}"
                sleep 1
                eject_eject_eject
                ;;
            *)
                log "\n${ylw}What the Hell was that?${rst} I clearly said 'press ${grn}Y${rst} for Yes, or ${red}N${rst} to exit', soo ...\n"
                ;;
        esac
    done
}

# + ----------------------------------------------------------------------------------------------------------------- +

is_root() {
    # Rootcheck, beeyotch!

    #if [ "$(id -u)" -eq 0 ]; then # (sh)
    if [ "$EUID" -eq 0 ]; then     # (bash)
        return 0 # User is root
    else
        return 1 # User isn't root
    fi
}

# + ----------------------------------------------------------------------------------------------------------------- +

is_directory_empty() {

  if [ -z "$(ls -A "$1")" ]; then
    return 0  # empty
  else
    return 1  # not empty
  fi

}

# + ----------------------------------------------------------------------------------------------------------------- +

check_space() {
    # Check available drive space

    local path="$1"

    file_size=$(stat --printf="%s" "${path}")                              # File size in bytes
    available_space=$(df --output=avail "$(dirname "${path}")" | tail -1)  # Space in KB

    if (( available_space * 1024 < file_size )); then
        # No
        return 1
    else
        # Yer
        return 0
    fi
}

# + ----------------------------------------------------------------------------------------------------------------- +

cleanup() {
    # Final cleanup of our mess. (All tmp containers, tmp files, etc.)
    local how_clean="$1"

    case ${how_clean} in
        1)
            # Removes: Temporary container, database backup directory & sql file, if they exist.
            rm -f "${local_bak_path_full}"
            rm -rf "${tmp_prefix}/database"
            docker container rm -f "${pgs_tmp}" > /dev/null 2>&1
            return 0
            ;;
        2)
            # Comprehensive: Removes: Temp container, backup directory, sql file, logs, and potentially other files.
            rm -f "${local_bak_path_full}"                                        # .sql file
            rm -f "${tmp_path}"                                                   # .tar file
            rm -rf "${tmp_prefix}"                                                # our entire tmp folder
            docker container rm -f "${pgs_tmp}" > /dev/null 2>&1
            return 0
            ;;
        *)
            # Default cleanup: Removes only the temp container
            docker container rm -f "${pgs_tmp}" > /dev/null 2>&1
            return 0
            ;;
    esac
}

# + ----------------------------------------------------------------------------------------------------------------- +

footer() {
    # Our fond farewell. Parting is such sweet sorrow.

    log "\n${prp}${sep_full}${rst}"
    log "${prp}|${rst}$(chars " " 37)${script_title}$(chars " " 38)${prp}|${rst}"
    log "${prp}|${rst}$(chars " " 14)If you've found this useful a small token of gratitude for my work would go a long way =)$(chars " " 15)${prp}|${rst}"
    log "${prp}|${rst}$(chars " " 43)${ylw}${help_a_brother_out}${rst}$(chars " " 42)${prp}|${rst}"
    log "${prp}${sep_full}${rst}"
}

# + ----------------------------------------------------------------------------------------------------------------- +

eject_eject_eject() {
    # Show the exit msg and bail outta this app

    log "${red}    ✘ ${exit_msg}${rst}"
    cleanup 0 # container only
    footer
    exit 1
}

# + ----------------------------------------------------------------------------------------------------------------- +

compress() {
    # This will handle whether the user set the compress option to any numerical value, including 0 to stay uncompressed.
    # If 0, just returns as if nothing happened; if 1 gzip compresses, 2 bz2 compresses, all else fails.
    # This allows calling this func no matter what; even if the user chose not to compress.

    # VALIDATE: numeric value was chosen. No strings, bitch!
    if ! [[ "${compress}" =~ ^[0-9]+$ ]]; then
        log "${red}     ✘ Compression option must be numeric. 1 or 2 to compress; 0 to leave uncompressed.${rst}"
        return 1
    fi

    # So, if user chose to compress, lets get on with it.
    if [[ ${compress} -gt 0 ]]; then

        local nope="File will stay uncompressed."
        local tool=""
        local ntool="" # This is the opposite tool of the selected too.

        # VALIDATE: valid path of file to compress. Likely done before this func was called, but never hurts to re-validate.
        if [[ ! -f "${tmp_path}" ]]; then
            log "${red}     ✘ File to compress doesn't exist. Tryin to pull a fast one?:${rst} ${tmp_path}"
            return 1
        fi

        # VALIDATE: the temp dir has enough space to compress the file
        if ! check_space "${tmp_path}"; then
            log "${red}     ✘ Not enough space to compress:${rst} ${tmp_path} ${red}${nope}.${rst}"
            return 1
        else
            log "${grn}     ✔ Plenty of space for your compressed backup${rst}"
        fi

        # VALIDATE: the type of compression chosen
        if [[ ${compress} -eq 1 ]]; then
            tool="gzip"
            ntool="bzip2"
            ext=".gz"
        elif [[ ${compress} -eq 2 ]]; then
            tool="bzip2"
            ntool="gzip"
            ext=".bz2"
        else
            log "${red}     ✘ You've set your compression option to someting wong; ${nope} Should only be 1 or 2 to compress; you have this set:${rst} ${compress}"
            return 1
        fi

        # VALIDATE: make sure their tool choice is even installed, first.
        if ! command -v "${tool}" &> /dev/null; then
            log "${red}     ✘ Oopsy Daisy: ${tool} isn't installed; what were you thinking? That you could just get away with it? I don't think so! Install it, switch to ${ntool}, or disable compression. ${nope}${rst}"
            return 1
        fi

        # -----

        # Must've gotten past all the guard dogs above; let's go!
        log "${cyn}   ¤ [${tool}]: Compressing backups to:${rst} ${tmp_path}${ext}"

        if ! "${tool}" "${tmp_path}"; then
            log "${red}     ✘ ${tool}: Compression failed. ${nope}${rst}"
            return 1
        fi

        # Show the final compressed size
        log "${grn}     ✔ Compressed backup size:${rst}$(chars " " 8)$(kb_to_mb "$(du -k "${tmp_path}${ext}" | cut -f1)")"
        return 0

    fi

    return 0
}

# + ----------------------------------------------------------------------------------------------------------------- +

pgs_start() {
    # Pass "old" to this func to start the old Postgres version container; "new" starts the new Postgres version.

    local arg="$1"
    local pgs_ver=1

    # Set which version of the PGS container we're starting
    if [ "$arg" = "old" ]; then
        pgs_ver=${pgs_oldver}
    elif [ "$arg" = "new" ]; then
        pgs_ver=${pgs_newver}
    else
        # If dumbass (probably me) passed the wrong argument, return 1.
        # We *could* default $arg to something like "latest", but might not be what we want.
        log "${red}    ✘ Error: Invalid argument for pgs_start (should either be \"old\" or \"new\"):${rst} ${arg}"
        eject_eject_eject
    fi

    # Without "> /dev/null 2>&1" you get the container hash. Could be useful in debugging.
    docker container run --name "${pgs_tmp}" -d \
    -v "${data_vol}" -v "${bak_vol}" \
    -e POSTGRES_DB="${pgs_db}" -e POSTGRES_USER="${pgs_user}" -e POSTGRES_PASSWORD="${pgs_pw}" \
    --net="${pgs_net}" \
    postgres:"${pgs_ver}" > "${tmp_prefix}/logs/container-run-${pgs_ver}.log" 2>&1

}

# + ----------------------------------------------------------------------------------------------------------------- +

wait_ready() {

    local pgs_ver="$1"
    local count=0

    # Wait for PostgreSQL to be ready. Show the container's logs; useful when troubleshooting.
    log "\n${cyn}  Waiting for Postgres:${rst}${pgs_ver} ${cyn}container (${pgs_tmp}) to be ready; (ctrl+c to abort)${rst}\n"

    until docker container logs "${pgs_tmp}" 2>&1 | grep -q "database system is ready to accept connections"; do

        log "${cyn}    ∞ ${grn}[$((count+1))/${max_retries}]${rst}${cyn} Checking${rst}\n"

        sleep "${sleep_int}"

        local count=$((count+1))

        if [[ "$count" -ge "$max_retries" || "$(docker inspect "${pgs_tmp}" --format='{{.State.Status}}')" == "exited" ]]; then
            log "${red}    ✘ POOP${rst}\n"
            docker inspect "${pgs_tmp}" --format='{{json .State}}' | jq

            if [[ "$(docker inspect "${pgs_tmp}" --format='{{.State.Status}}')" == "exited" ]]; then
                printf "\n"
                docker container logs -f "${pgs_tmp}"
                log "\n\n${red}  ✘ DAMN!${rst} ${pgs_tmp} ${red}did not become ready! ${exit_msg}${rst}"
            fi

            footer
            exit 1
        fi
    done

    log "${grn}    ✔ ${pgs_tmp} container running! Postgres${rst} v$(docker exec "${pgs_tmp}" psql --version | awk '{print $3}')"
}

# + ----------------------------------------------------------------------------------------------------------------- +

check_perms() {
    # Ensures the specified directory has permissions set to at least 755. Sets permissions if needed.

    local data_path="$1"

    # Validate input
    if [[ -z "$data_path" ]]; then
        echo "Usage: check_perms <path>"
        return 1
    fi

    # Verify the path is a directory
    if [[ ! -d "$data_path" ]]; then
        log "${red}    ✘ Error:${rst} ${data_path} ${red}is not a directory.${rst}"
        return 1
    fi

    # Check and set permissions if necessary
    local current_perms

    current_perms=$(stat -c "%a" "$data_path")

    if [[ "$current_perms" -lt 755 ]]; then
        chmod 755 "$data_path" || {
            log "${red}    ✘ Error: Couldn't set permissions on${rst} ${data_path}."
            return 1
        }
    fi
    return 0
}

# + ----------------------------------------------------------------------------------------------------------------- +

check_user() {
    # Checks the Linux User/Owner of their Postgres data directory to see if it's one compatible w/Postgres' requirements.

    if [[ "${show_dbg:-0}" -eq 1 ]]; then

        # Troubleshooting Check: Get the owner of the directory
        local local_data_owner=$(stat -c '%U' "$local_data_path")

        log "\n${dbg_bar_top}"
        log "${dbg_vert}"

        # Check if the owner of the local data path is neither root nor postgres
        if [ "$local_data_owner" != "root" ] && [ "$local_data_owner" != "postgres" ]; then
            log "${dbg_vert}${red}  ATTENTION: Your current local data directory:${rst} ${local_data_path}"
            log "${dbg_vert}${red}  is owned by${rst} ${local_data_owner} ${red}and NOT${rst} root ${red}or${rst} postgres${red}, which may cause issues, including the Postgres container${rst}"
            log "${dbg_vert}${red}  thinking you want to do a FRESH data init rather than using your EXISTING data.${rst}"
            log "${dbg_vert}${red}  You may want to stop this script${rst} (ctrl+c) ${red}right now and${rst} chown ${red}that directory to either${rst} root ${red}or${rst} postgres${red}.${rst}"
            # TODO(?): just automatically DO this for them instead? Or give them an option to do it for them here?
        fi

        log "${dbg_vert}"
        log "${dbg_bar_btm}\n"
    fi
}

# + ----------------------------------------------------------------------------------------------------------------- +

kb_to_mb() {
    # Convert kilobytes to megabytes. Nobody likes ridiculously long numbers (unless it's their own money).

    if [ $# -ne 1 ]; then
        echo "Usage: kb_to_mb <size_in_kb>"
        return 1
    fi

    local kb=$1
    local mb=$(echo "scale=2; $kb / 1024" | bc)

    if [ "$(echo -e "$mb < 1" | bc -l)" -eq 1 ]; then
        echo -e "$kb KB"
    else
        echo -e "$mb MB"
    fi
}

# + ----------------------------------------------------------------------------------------------------------------- +

pgs_db_alert() {

    # Give em a lil heads-up so they don't freak out, like I did.
    echo -e "\n${dbg_bar_top}"
    echo -e "${dbg_vert}$(chars " " 118)${dbg_vert}"
    echo -e "${dbg_vert}${grn}  NOTE: You can likely ignore the (potential) following message saying${rst}$(chars " " 48)${dbg_vert}"
    echo -e "${dbg_vert}${grn}$(chars " " 8)'yada yada yada database system will be owned by user \"postgres\".'$(chars " " 44)${rst}${dbg_vert}"
    echo -e "${dbg_vert}${grn}$(chars " " 9)More info (see the blurb under POSTGRES_USER environment variable):${rst} https://hub.docker.com/_/postgres$(chars " " 8)${dbg_vert}"
    echo -e "${dbg_vert}$(chars " " 118)${dbg_vert}"
    echo -e "${dbg_bar_btm}"
}

# + ----------------------------------------------------------------------------------------------------------------- +

var_dump() {
    # Note: color scheme don't mean anything in particular; just staggered to make reading them a bit easier.

    echo -e "\n${dbg_bar_top}"
    echo -e "${dbg_vert}"
    echo -e "${dbg_pointer}  ${grn}POSTGRES_DB:$(chars " " 18)[${rst}\$pgs_db${grn}]${rst}$(chars " " 18)${pgs_db}"
    echo -e "${dbg_pointer}  ${grn}POSTGRES_USER:                [${rst}\$pgs_user${grn}]${rst}                ${pgs_user}"
    echo -e "${dbg_pointer}  ${grn}POSTGRES_PASSWORD:            [${rst}\$pgs_pw${grn}]${rst}                  ${pgs_pw}"
    echo -e "${dbg_vert}"
    echo -e "${dbg_pointer}  ${cyn}NETWORK:                      [${rst}\$pgs_net${cyn}]${rst}                 ${pgs_net}"
    echo -e "${dbg_vert}"
    echo -e "${dbg_pointer}  ${prp}DATA VOLUME:                  [${rst}\$data_vol${prp}]${rst}                ${data_vol}"
    echo -e "${dbg_pointer}  ${prp}BACKUP VOLUME:                [${rst}\$bak_vol${prp}]${rst}                 ${bak_vol}"
    echo -e "${dbg_pointer}  ${prp}BACKUP NAME:                  [${rst}\$bak_name${prp}]${rst}                ${bak_name}"
    echo -e "${dbg_vert}"
    echo -e "${dbg_pointer}  ${grn}LOCAL DATA PATH:              [${rst}\$local_data_path${grn}]${rst}         ${local_data_path}"
    echo -e "${dbg_pointer}  ${grn}LOCAL DATA PATH (full):       [${rst}\$local_data_path_full${grn}]${rst}    ${local_data_path_full}"
    echo -e "${dbg_pointer}  ${cyn}LOCAL BACKUP PATH:            [${rst}\$local_bak_path${cyn}]${rst}          ${local_bak_path}"
    echo -e "${dbg_pointer}  ${cyn}LOCAL BACKUP PATH: (full)     [${rst}\$local_bak_path_full${cyn}]${rst}     ${local_bak_path_full}"
    echo -e "${dbg_pointer}  ${cyn}LOCAL PARENT PATH:            [${rst}\$parent${cyn}]${rst}                  ${parent}"
    echo -e "${dbg_pointer}  ${grn}TMP PATH:                     [${rst}\$tmp_path${grn}]${rst}                ${tmp_path}"
    echo -e "${dbg_vert}"
    echo -e "${dbg_pointer}  ${ylw}CONTAINER BACKUP PATH:        [${rst}\$container_bak_path${ylw}]${rst}      ${container_bak_path}"
    echo -e "${dbg_pointer}  ${ylw}CONTAINER BACKUP PATH (full): [${rst}\$container_bak_path_full${ylw}]${rst} ${container_bak_path_full}"
    echo -e "${dbg_vert}"
    echo -e "${dbg_pointer}  ${grn}PGS OLDVER:                   [${rst}\$pgs_oldver${grn}]${rst}              ${pgs_oldver}"
    echo -e "${dbg_pointer}  ${grn}PGS NEWVER:                   [${rst}\$pgs_newver${grn}]${rst}              ${pgs_newver}"
    echo -e "${dbg_vert}"
    echo -e "${dbg_pointer}  ${cyn}TMP CONTAINER:                [${rst}\$pgs_tmp${cyn}]${rst}                 ${pgs_tmp}"
    echo -e "${dbg_pointer}  ${ylw}UPGRADE METHOD:               [${rst}\$upgrd_method${ylw}]${rst}            ${upgrd_method}"
    echo -e "${dbg_vert}"
    echo -e "${dbg_pointer}  ${prp}MAX RETRIES:                  [${rst}\$max_retries${prp}]${rst}             ${max_retries}"
    echo -e "${dbg_pointer}  ${prp}RETRY INTERVAL:               [${rst}\$sleep_int${prp}]${rst}               ${sleep_int}"
    echo -e "${dbg_vert}"
    echo -e "${dbg_pointer}  ${grn}COMPRESS BACKUP:              [${rst}\$compress${grn}]${rst}                ${compress}"
    echo -e "${dbg_pointer}  ${prp}MIN. DB SIZE:                 [${rst}\$bak_db_minsize${prp}]${rst}          ${bak_db_minsize}"
    echo -e "${dbg_vert}"
    echo -e "${dbg_bar_btm}\n"
}

# + Main Funcs ------------------------------------------------------------------------------------------------------ +

backup_db() {
    # BACKUP DATABASES ON SERVER

    log "\n${ylw}♦ Creating Database Backup of Postgres:${rst}${pgs_oldver}"
    log ""
    log "   ${cyn}¤ (container):${rst} ${container_bak_path_full}"
    log "   ${cyn}¤ (local):${rst}     ${local_bak_path_full}"

    # Ref: https://www.postgresql.org/docs/current/app-pg-dumpall.html
    # Dump Everything: Global objects (roles and tablespaces), schema (data definitions), databases, et. al.
    # NOTE: "quote all id's" is here to make PGS major version upgrades smoother (hopefully. *crossing fingers*)
    if ! docker exec -it "${pgs_tmp}" sh -c "pg_dumpall --quote-all-identifiers -U ${pgs_user} > ${container_bak_path_full}"; then
        log "\n${red}   ✘ Oh No: Database backup failed during Docker exec.${rst}"
        eject_eject_eject
    fi

    # Continue validation; validate db backup file exists
    if [[ ! -f "$local_bak_path_full" ]]; then
        log "\n${red}   ✘ SHiT:${rst} Database backup failed:${rst} '${local_bak_path_full}' ${red}does not exist.${rst}"
        eject_eject_eject
    fi

    # Ok, it exists, now check the file size (in KB) (must be equal or greater than $bak_db_minsize)
    local actual_size=$(du -k "$local_bak_path_full" | cut -f1)

    log "   ${cyn}¤ Validating DB backup size vs. minimum size you set (${rst}${bak_db_minsize} ${cyn}KB)${rst}"

    if [[ "$actual_size" =~ ^[0-9]+$ ]] && [[ "$bak_db_minsize" =~ ^[0-9]+$ ]] && [ "$actual_size" -lt "$bak_db_minsize" ]; then
        log "\n${red}   ✘ SHiT: Database backup failed${rst}"
        log "${red}   ✘ Backup file:${rst} ${local_bak_path_full} ${red}size is smaller than${rst} ${bak_db_minsize} KB. ${red}(Actual size:${rst} ${actual_size} KB${red}).\n"
        log "${red}   Troubleshooting${rst}"
        log "${red}     ¤ Are your credentials correct?${rst}"
        log "${red}     ¤ Does your${rst} ${local_data_path} ${red}still have your 'old' data in it? (hint: it should when doing a backup)${rst}"

        if [[ "${show_dbg:-0}" -ne 1 ]]; then
            log "${dbg_bar_top}"
            # But first, be a lamb and clean up the mess for the user.
            log "${dbg_vert}${red}   ✘ Deleting undersized DB backup file${rst}"
            log "${dbg_bar_btm}"

            # In debug mode we'll keep the bad file in case we want to examine it; else delete it.
            rm -f "${local_bak_path_full}"
        fi
        eject_eject_eject
    fi
    log ""
    log "${grn}   ✔ Database backup success! Backup size:${rst}$(chars " " 15)$(kb_to_mb "${actual_size}")"
}

# + ----------------------------------------------------------------------------------------------------------------- +

backup_data() {
    # BACKUP DATA DIRECTORY

    # Copy the current (old) data dir to a backup dir
    log "\n${ylw}♦ Creating Data Backup of Postgres:${rst}${pgs_oldver} ${ylw}at:${rst} ${tmp_path}"
    log ""
    log "${grn}   ¤ Pausing${rst} ${pgs_tmp} ${grn}so no data changes while we're working${rst}"
    docker container pause "${pgs_tmp}" > /dev/null 2>&1

# ---------------------------------------------------------------------------------------------------------------------

    # Create a tar file of the data dir
    tar -cf "${tmp_path}" -C "${parent}" data > "${tmp_prefix}/logs/data-tar.log" 2>&1

# ---------------------------------------------------------------------------------------------------------------------

    # VALIDATE: Data backup. 1st step is simply confirming the backup tar does in fact, exist.
    if [[ ! -f "$tmp_path" ]]; then
        log "${red}   ✘ SHiT: Data backup failed:${rst} '${tmp_path}' ${red}(i.e. the tar file we were trying to create) does not exist. ${exit_msg}${rst}"
        eject_eject_eject
    fi

    log "${cyn}   ¤ Confirming data backup matches original data directory${rst}"

    # VALIDATE: Compare tar archive with directory
    if tar -df "${tmp_path}" -C "${parent}"; then
        log "${grn}     ✔ No differences found; the archive and directory are twinsies.${rst}"
    else
        log "${red}     ✘ Differences found; the archive and directory are NOT identical.${rst}"
        cleanup 2 # Remove the bad .tar file + literally everything else we've created; it's a bust.
        eject_eject_eject
    fi

# ---------------------------------------------------------------------------------------------------------------------

    # Add the DB backup to the Data backup, so everything is in 1 file, for portability (delete first if previously exists)
    rm -rf "${tmp_prefix}/database" && mkdir "${tmp_prefix}/database"

    # Copy DB backup to the above dir for adding to the archive. We're keeping a copy in it's original location for now for the restore function later.
    cp "${local_bak_path_full}" "${tmp_prefix}/database"

    # Add the above dir + DB backup to the tar
    log "${cyn}   ¤ Adding backed up database .sql to archive for portability (find it under /database in the final package)${rst}"

    if ! tar -rf "${tmp_path}" -C "/${tmp_prefix}" database/ > "${tmp_prefix}/logs/merge-backups.log" 2>&1; then
        log "${red}     ✘ SHiT: Adding your database backup to the data backup failed.${rst}"
        eject_eject_eject
    fi

# ---------------------------------------------------------------------------------------------------------------------

    # Pack it if ya wanna
    compress

    # All done, move the backup to ${final_destination}
    if mv "${tmp_path}${ext}" "${final_destination}"; then
        log ""
        log "${grn}   ✔ Data backup success!${rst}"
    else
        log ""
        log "${red}   ✘ SHiT: Had trouble moving the final backup to:${rst} ${final_destination}"
        log "${red}$(chars " " 6)but the${rst} ${grn}backup was still successful${rst} ${red}and may still be here:${rst} ${tmp_path}${ext}"
        log "${red}$(chars " " 6)You should pause a moment to manually move it to wherever you want it saved before continuing."
        log "$(chars " " 6)Since this isn't a fatal error, the rest of the script can continue, but you won't have a backup.${rst}\n"
        log "${ylw}   Press ENTER to proceed or ctrl+c to exit ...${rst}"
        read -r
    fi
}

# + ----------------------------------------------------------------------------------------------------------------- +

prepare_data_dir() {
    # Prepares, Validates, & Cleans Data directory.
    #
    # Does several things in preparation for the upgrade, in order:
    #
    #   EXISTS
    #     - Validates: Linux User of the user's Postgres Data directory: ${local_data_path}
    #     - Validates: Directory's permissions to meet what Postgres requires (minimum of 755)
    #     - Empties:   User's Data directory, as required for an upgrade by Postgres,
    #                  or you'll get an error like: 'initdb: error: directory "/var/lib/postgresql/data" exists but
    #                  is not empty'
    #
    #   DOESN'T EXIST
    #     - Creates:   The Data directory: ${local_data_path}
    #     - Sets:      It's owner to the one you entered in the options above: ${pgs_user}
    #     - Sets:      It's permissions to 755

    if [[ "${just_delete_data_dir:-0}" -ne 0 ]]; then

        # TODO:
        log "just delete the data dir"
    fi

    log "\n${ylw}♦ Preparing Data Directory for Postgres:${rst}${pgs_newver}"
    log ""

    if [[ -d "${local_data_path}" ]]; then

        # ${local_data_path} DOES already exist (i.e. if we previously backed it up)
        # Only need to confirm it's User and Permissions now, and then empty it because the upgrade requires it empty.
        # If it existed & we backed it up it'll still have it's data inside it, so needs emptying.

        # Does this USER have the abilities that Postgres wants?
        check_user

        if check_perms "${local_data_path}"; then
            log "${grn}   ✔ Data directory permissions looking good${rst}"
        else
            log "${red}   ✘ Something shit the bed whilst checking/setting permissions on your existing Data directory.${rst}"
            log "${red}   Troubleshooting${rst}"
            log "${red}     ¤ Try manually setting permissions on${rst} ${local_data_path} ${red}to at minimum 755 and restart this script.${rst}"
            log "${red}     ¤ Is the User able to set permissions on that directory?.${rst}"
            # TODO (?): I COULD also pause the script here and tell the user to manually go set permissions on it and then press Enter to continue.
            eject_eject_eject
        fi

        # Friendly heads-up
        local dont_freak="(Postgres requires it empty when upgrading)"

        # Empty the current (old) data folder, as the upgrade expects it empty.
        if ! is_directory_empty "${local_data_path}"; then

            if find "${local_data_path}" -mindepth 1 -delete; then
                log "${grn}   ✔ Data directory cleared. ${dont_freak}${rst}"
            else
                log "${red}   ✘ Something shit the bed whilst clearing the Data directory. ${dont_freak}${rst}"
                log "${red}   Troubleshooting${rst}"
                log "${red}     ¤ Do you have permissions properly set to delete${rst} ${local_data_path} ${red}'s contents?${rst}"
                log "${red}     ¤ Is the User able to set permissions on that directory?.${rst}"
                log "${red}     ¤ Try manually setting it's permissions to at minimum 755 and restart this script.${rst}"
                # TODO (?): I COULD also pause the script here and tell the user to manually go empty it and then press Enter to continue.
                eject_eject_eject
            fi
        fi
    else
        # ${local_data_path} doesn't exist

        # NOTE: Kinda weird it wouldn't exist now after we already backed it up previously, but validation
        #       is still always a good thing anyway. User's sometimes do weird shit.

        # NOTE: When running the container, which this script is designed for, from my understanding this is likely not needed,
        #       as the container auto-creates the data folder if it doesn't already exist. BUt just to be a bit more thorough
        #       let's create it anyway (including all it's perms/user/etc.
        #       Maybe sometime I'll set a flag option to skip this part?

        # Create a new Data directory
        if mkdir "${local_data_path}"; then

            log "${grn}    ✔ Data directory created${rst}"

            # Set User:Group. Must be that of which will work happily with Postgres

            # Not sure using the $pgs_user var is best option, as user may not have set a proper one (that postgres likes) for this.
            if chown "${pgs_user}:${pgs_user}" "${local_data_path}"; then
            #chown root:root "${local_data_path}"
            #chown postgres:postgres "${local_data_path}"

                # Check/set proper permissions on the new Data directory
                if ! check_perms "${local_data_path}"; then
                    log "${red}    ✘ Something shit the bed whilst checking/setting permissions on your shiny new Data directory.${rst}"
                    log "${red}   Troubleshooting${rst}"
                    log "${red}$(chars " " 108)¤ Try manually setting permissions on${rst} ${local_data_path} ${red}to at minimum 755 and restart this script.${rst}"
                    eject_eject_eject
                fi

                log "${grn}    ✔ Data directory user & permissions set${rst}"
            else
                # TEST THIS
                # Error chowning
                log "${red}    ✘ Hate to tell ya this, but ran into a problem trying to change the owner on your shiny new Data directory to:${rst} ${pgs_user}:${pgs_user}"
                log "${red}   Troubleshooting${rst}"
                log "${red}$(chars " " 108)¤ Try to manually chown the directory${rst} (i.e. chown ${pgs_user}:${pgs_user} ${local_data_path}${red}, and restart this script.${rst}"
                log "${red}$(chars " " 108)¤ Remember that the user you chown it to must also be a user that Postgres wants.${rst}"
                eject_eject_eject
            fi

            # Does this USER have the abilities that Postgres wants?
            # This is just an added check after the script successfully chown's the new Data directory.
            check_user
        else
            # TEST THIS
            log "${red}    ✘ Bad news. Well, not THAT bad; just had a small problem creating the Data directory at:${rst} ${local_data_path}"
            log "${red}   Troubleshooting${rst}"
            log "${red}$(chars " " 108)¤ Try to manually create the directory${rst} (i.e. mkdir ${local_data_path})${red}, and restart this script.${rst}"
            eject_eject_eject
        fi
    fi
    return 0
}

# + ----------------------------------------------------------------------------------------------------------------- +

restore_data() {
    # RESTORE BACKED UP DATA

    # Reference: https://chatgpt.com/share/674dd1ea-3d14-8010-8719-7f26df191c1c

    # Note that we used pg_dumpall, which needs psql, not pg_restore.
    log "\n${ylw}♦ Restoring Database to Postgres:${rst}${pgs_newver}"
    log ""
    log "${grn}   ¤ Sit tight, this might take a minute ...${rst}"

    # rotating_cursor
    local log_path="${tmp_prefix}/logs/sql-import.log"

    # Import the SQL
    docker exec -i "${pgs_tmp}" sh -c "psql -U ${pgs_user} -d ${pgs_db} -f ${container_bak_path_full}" > "${log_path}" 2>&1 #&

    # Commented out lines are for the rotating cursor, but the import happens so fast I just skipped it. Left for posterity.
    #local pid=$!

    # Start the rotating cursor
    #rotating_cursor "$pid"

    # Wait for the process to finish
    #wait "$pid"

    local result=$?

    if [[ $result -eq 0 ]]; then
        log ""
        log "${grn}   ✔ Database import successful${rst}"
    else
        log ""
        log "${red}   ✘ Ouch, database import failed. Check the log for details:${rst} ${log_path}"
        # Let's just spit it out on screen since we're in debug mode. Potentially ugly, but usually debug modes are.
        [[ "${show_dbg:-0}" -eq 1 ]] && cat "${log_path}"
        eject_eject_eject
    fi
    return 0
}

# + ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ +
# | PROGRAM: BEGIN                                                                                                    |
# + ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ LET'S ROCK +

# Clear screen first?
[[ "${cls:-1}" -eq 1 ]] && clear

# Remove any previous upgrade.log
rm -f "${tmp_prefix}/logs/upgrade.log"

# Please allow myself to introduce ... myself
log "${prp}${sep_full}${rst}"
log "${prp}|${rst}$(chars " " 35)${script_title} v${script_ver}$(chars " " 35)${prp}|${rst}"
log "${prp}${sep_full}${rst}\n"

# Scold em if ya got em!
if ! is_root; then
    log "${red}✘ Script is not running as root! (${rst}Please use sudo${red})${rst}"
    eject_eject_eject
fi

# Disclaimer
[[ "${disclaimer:-1}" -ne 0 ]] && danger_will_robinson

# Dump Vars
[[ "${show_dbg:-0}" -eq 1 ]] && var_dump

# Create the tmp & logs directories if they don't exist
[[ ! -d "${tmp_prefix}" ]] && mkdir "${tmp_prefix}"
[[ ! -d "${tmp_prefix}/logs" ]] && mkdir "${tmp_prefix}/logs"

# STEP 1 ---------------------------------------------------- STARTUP A PGS CONTAINER OF THE 'OLD' (PREVIOUS) VERSION +

log "${cyn}$(chars "═" 120)${rst}"
log ""
log "${prp}♦ Creating a Temporary Container named${rst} ${pgs_tmp} ${prp}for Postgres:${rst}${pgs_oldver} ${prp}(your 'old' version)${rst}"

# Remove the tmp container if previously running
if docker ps -a | grep -q "${pgs_tmp}"; then
    cleanup 0 # container only
    log "${grn}   ✔ Previously running ${pgs_tmp} removed${rst}"
fi

# Let's see what the full command looks like so we can look for potential errors. (enable command tracing)
#if [[ "${show_dbg:-0}" -eq 1 ]] && set -x

# Fire it UP
pgs_start "old"

# If we keep it on, the screen will just look like a mess from here on out. (disable command tracing)
#if [[ "${show_dbg:-0}" -eq 1 ]] && set +x

[[ "${show_dbg:-0}" -eq 1 ]] && pgs_db_alert

wait_ready "${pgs_oldver}"

# STEP 2 ------------------------------------------------------------------------------------ BACKUP SERVER DATABASES +

backup_db

# STEP 3 ---------------------------------------------------------------------------------- BACKUP OLD DATA DIRECTORY +

backup_data

# STEP 3.5 ----------------------------------------------------------------------------------- PREPARE DATA DIRECTORY +

prepare_data_dir

# STEP 4 --------------------------------------------------------------- STARTUP A PGS CONTAINER OF THE 'NEW' VERSION +

log "\n${prp}♦ Creating a Temporary Container named${rst} ${pgs_tmp} ${prp}for Postgres:${rst}${pgs_newver} ${prp}(your 'new' version)${rst}"
log ""

# Remove 'old' version container ...
if docker ps -a | grep -q "${pgs_tmp}"; then
    cleanup 0 # container only
    log "${grn}   ✔ Removed${rst} v${pgs_oldver} ${grn}${pgs_tmp} container${rst}"
fi

# ... and start 'new' version container
pgs_start "new"

wait_ready "${pgs_newver}"

# STEP 5 ------------------------------------------------------------------------------------- RESTORE BACKED UP DATA +

restore_data

# -------------------------------------------------------------------------------------------------------------- DONE +

# Just container + database directory
cleanup 1

log ""
log "${cyn}$(chars "═" 120)${rst}"
log ""
log "${grn}✔ Congrats! You now have a beautiful bouncing baby backup of your previous Data directory + SQL at:${rst}"
log "$(chars " " 17)${final_destination}/${bak_name}.tar${ext}"
log ""
log "${ylw}Go ahead and start up your Postgres:${rst}${pgs_newver} ${ylw}container your usual way and you should be all upgraded!${rst}"
log ""
log "${cyn}If interested, logs are here:${rst} ${tmp_prefix}"

footer

# Ding!
[[ "${ding:-1}" -eq 1 ]] && echo -e "\a"

# + ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ +
# | PROGRAM: END                                                                                                      |
# + ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ BUH BYE +
