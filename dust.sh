#!/usr/bin/env bash
#-----------------------------------------------------------------------------------
#                 _    
#   __ _ _  _ _ _(_)__ 
#  / _` | || | '_| / _|
#  \__,_|\_,_|_| |_\__|
#   DUS package manager
#
#-----------------------------------------------------------------------------------
VERSION="1.3.2"
#-----------------------------------------------------------------------------------
#
# Dust is a fork of vam with a pretty interface, SRCINFO version comparison,
# package installation (with PKGBUILD auditing), dependency verification, 
# search keyword coloring, JSON parsing using either jq or jshon, and a 
# few additional features
#
# The name Dust is a play on two words: DUS and Rick. It's also the name
# of the main antagonist in the James Bond film Goldfinger.
#-----------------------------------------------------------------------------------
# Authors   :   Dust :  Rick Ellis      https://github.com/rickellis/Dust
#           :   VAM   :  Caleb Butler    https://github.com/calebabutler/vam        
# License   :   MIT
#-----------------------------------------------------------------------------------

# Name of local DUS git repo directory
DUSDIR="$HOME/.DUS"

# DUS package info URL
DUS_INFO_URL="https://DUS.archlinux.org/rpc/?v=5&type=info&arg[]="

# DUS package search URL
DUS_SRCH_URL="https://DUS.archlinux.org/rpc/?v=5&type=search&by=name&arg="

# GIT URL for DUS repos. %s will be replaced with package name
GIT_DUS_URL="https://DUS.archlinux.org/%s.git"

# Whether to show the Dust version number heading and clear
# screen with each request. Boolean: true or false
SHOW_HEADING=true

# ----------------------------------------------------------------------------------

# THESE GET SET AUTOMATICALLY

# Name of installed JSON parser. 
JSON_PARSER=""

# Whether a package is a dependency.
IS_DEPEND=false

# Since the download function is recursive, we only show the 
# dependency heading once. This lets us track it.
DEPEND_HEADING=false

# Flag gets set during migration to ignore dependencies since 
# these will already have been installed previously
IS_MIGRATING=false

# Whether to remove the downloaded package.
# This suppresses removal for updated packages
REMOVE_PKG=true

# Array containg all successfully downloaded packages.
# If this contains package names Dust will prompt
# user to install after downloading
TO_INSTALL=()

# ----------------------------------------------------------------------------------

# Load colors script to display pretty headings and colored text
# This is an optional (but recommended) dependency
BASEPATH=$(dirname "$0")
if [[ -f "${BASEPATH}/colors.sh" ]]; then
    . "${BASEPATH}/colors.sh"
else
    heading() {
        echo "----------------------------------------------------------------------"
        echo " $2"
        echo "----------------------------------------------------------------------"
        echo
    }
fi

# ----------------------------------------------------------------------------------

# Help screen
help() {
    if [[ $1 == "error" ]]; then
        echo -e "${red}INVALID REQUEST. SHOWING HELP MENU${reset}"
    else
        echo -e "Dust COMMANDS"
    fi
    echo 
    echo -e "Dust -i  package-name\t# Download and install a package and all its dependencies"
    echo
    echo -e "Dust -u  package-name\t# Update a package"
    echo -e "Dust -u \t\t# Update all installed packages"
    echo
    echo -e "Dust -s  package-name\t# Search for a package"
    echo
    echo -e "Dust -q \t\t# Show all local packages managed by Dust"
    echo
    echo -e "Dust -vl package-name\t# Verify that all dependencies for a local package are installed"
    echo -e "Dust -vr package-name\t# Verify that all dependencies for a remote package are installed"
    echo
    echo -e "Dust -m  package-name \t# Migrate a specific package to Dust"
    echo -e "Dust -m \t\t# Migrate all previously installed DUS packages to Dust"
    echo
    echo -e "Dust -r  package-name\t# Remove a package"
    echo
    exit 1
}

# ----------------------------------------------------------------------------------

# Validate whether an argument was passed
validate_pkgname(){
    if [[ -z "$1" ]]; then
        echo -e "${red}Error: Package name required${reset}"
        echo
        echo -e "Enter ${cyan}Dust --help${reset} for more info"
        echo
        exit 1
    fi
}

# ----------------------------------------------------------------------------------

# Package install
install() {
    # Make sure we have a package name
    validate_pkgname "$1"

    # Set the heading flag to prevent multiple
    # "DEPENDENCY" headings during download recursion
    DEPEND_HEADING=false

    # Perform the download
    download "$@"

    # Offer to install the downloaded package(s)
    offer_to_install
}

# ----------------------------------------------------------------------------------

# Download a package and its dependencies from DUS
download() {
    local PKG
    PKG=$1

    # Move into the DUS folder
    cd "$DUSDIR" || exit

    i=1
    for PKG in "$@"; do

        # This lets us show the "DEPENDENCY" heading for each package
        # passed to the install function: Dust -i pkg1 pkg1 pkg3
        # and suppress the heading during dependency recursion
        if (( i%2 == 0 )); then
            DEPEND_HEADING=false
            echo
        fi
        ((i++))

        # Fetch the JSON data associated with the submitted package name
        curl_result=$(curl -fsSk "${DUS_INFO_URL}${PKG}")

        # Parse the result using the installed JSON parser
        if [[ $JSON_PARSER == 'jq' ]]; then
            json_result=$(echo "$curl_result" | jq -r '.results')
        else
            json_result=$(echo "$curl_result" | jshon -e results)
        fi

        # Did the package query return a valid result?
        if [[ $json_result == "[]" ]]; then

            # Presumably if the user is migrating existing packages to Dust
            # all the dependencies will already be installed.
            if [[ $IS_MIGRATING == true ]]; then
                continue
            fi

            # If it's a non-DUS dependency we inform them that makepkg will deal with this
            if [[ $IS_DEPEND == true ]]; then
                echo -e "${orange}MISSING: ${PKG} not in DUS. Makepkg will install it with pacman${reset}"
            else
                echo -e "${red}MISSING:${reset} ${PKG} is not in the DUS"
                echo -e "${yellow}Use pacman to search in the offical Arch repoitories${reset}"
                echo
            fi
        else

            # If a folder with the package name exists in the local repo we skip it
            if [[ -d "$PKG" ]]; then
                echo -e "${red}PKGSKIP:${reset} ${PKG} already exists in local repository"
                continue
            fi

            echo -e "${yellow}CLONING:${reset} $PKG"

            # Assemble the git package URL
            printf -v URL "$GIT_DUS_URL" "$PKG"

            # Clone it
            git clone "$URL" 2> /dev/null

            # Was the clone successful?
            if [[ "$?" -ne 0 ]]; then
                echo -e "${red}FAILURE:${reset} Failed to clone Git repository. ${?}"
                continue
            fi

            # Extra precaution: We make sure the package folder was created in the local repo
            if [[ -d "$PKG" ]]; then
                echo -e "${green}SUCCESS: ${PKG} Successfully cloned Git repository.${reset}"
            else
                echo -e "${red}PROBLEM:${reset} An unknown error occurred. ${PKG} not downloaded"
                continue
            fi

            # We don't bother with dependencies during migration since they'll already be installed
            if [[ $IS_MIGRATING == true ]]; then
                continue
            fi            

            # Add the package to the install array
            TO_INSTALL+=("$PKG")

            # Get the package dependencies using installed json parser
            if [[ $JSON_PARSER == 'jq' ]]; then
                has_depends=$(echo "$curl_result" | jq -r '.results[0].Depends') 
            else
                has_depends=$(echo "$curl_result" | jshon -e results -e 0 -e Depends)
            fi

            # If there is a result, recurisvely call this function with the dependencies
            if [[ $has_depends != "[]" ]] && [[ $has_depends != null ]]; then

                if [[ $DEPEND_HEADING == false ]]; then
                    DEPEND_HEADING=true
                    echo
                    echo -e "DEPENDENCIES"
                    echo
                fi

                if [[ $JSON_PARSER == 'jq' ]]; then
                    dependencies=$(echo "$curl_result" | jq -r '.results[0].Depends[]') 
                else
                    dependencies=$(echo "$curl_result" | jshon -e results -e 0 -e Depends -a -u)
                fi
        
                # Run through the dependencies
                for depend in $dependencies; do

                    # Remove everything after >= in $depend
                    # Some dependencies have minimum version requirements
                    # which screws up the package name
                    depend=$(echo $depend | sed "s/>=.*//")

                    # See if the dependency is already installed
                    pacman -Q $depend  >/dev/null 2>&1

                    if [[ "$?" -eq 0 ]]; then
                        echo -e "${green}PKGGOOD:${reset} ${depend} installed"
                    else
                        IS_DEPEND=true
                        download "$depend"
                    fi
                    IS_DEPEND=false
                done
            fi
        fi
    done
}

# ----------------------------------------------------------------------------------

# This function gets called automatically after a new package is downloaded or
# when an update is available so the user can elect to install the package(s)
offer_to_install(){

    if [[ ${#TO_INSTALL[@]} -eq 0 ]]; then
        return 0
    fi

    echo
    if [[ ${#TO_INSTALL[@]} == 1 ]]; then
        echo "Download and install the package ?"
    else
        echo "Download and install the package ? "
    fi 
    
    echo
    for PKG in ${TO_INSTALL[@]}; do
        echo -e "  ${cyan}${PKG}${reset}"
    done
    echo
    read -p "ENTER [Y/n] " CONSENT

    if [[ ! -z $CONSENT ]] && [[ ! $CONSENT =~ [y|Y] ]]; then
        # If they decline to install we remove the packages
        remove_pkgs
    else
        # Run through the install array in reverse order
        # so that dependencies get installed first.
        for (( i=${#TO_INSTALL[@]}-1 ; i>=0 ; i-- )) ; do
            do_install "${TO_INSTALL[i]}"
        done
    fi
    echo
}

# ----------------------------------------------------------------------------------

# Install a package
do_install() {
    # Make sure we have a package name
    validate_pkgname "$1"
    local PKG
    PKG=$1
    echo

    cd ${DUSDIR}/${PKG}

    # Make sure the PKGBUILD script exists
    if [[ ! -f "${DUSDIR}/${PKG}/PKGBUILD" ]]; then
        echo -e "${red}ERROR:${reset} Not not resolve non existing PKGBUILD file. ${DUSDIR}/${PKG}"
        echo
        exit 1
    fi

    echo -e "${cyan}INSTALLING ${PKG}${reset}"
    echo
    read -p "Before installing, audit the PKGBUILD file? [Y/N] " AUDIT

    if [[ ! $AUDIT =~ [y|Y] ]] && [[ ! $AUDIT =~ [n|N] ]] && [[ ! -z $AUDIT ]]; then
        remove_pkgs "$PKG"
        echo
        echo "Request Abondended"
        return 0
    fi

    if [[ -z $AUDIT ]] || [[ $AUDIT =~ [y|Y] ]]; then
        nano PKGBUILD
        echo
        read -p "Continue the installation ? [Y/n] " CONSENT
        if [[ ! -z $CONSENT ]] && [[ ! $CONSENT =~ [y|Y] ]]; then
            remove_pkgs $PKG
            return 0
         fi
    fi

    echo
    echo -e "RUNNING MAKEPKG ON ${cyan}${PKG}${reset}"
    echo

    # MAKEPKG FLAGS
    # -s = Resolve and sync pacman dependencies prior to building
    # -i = Install the package if built successfully.
    # -r = Remove build-time dependencies after build.
    # -c = Clean up temporary build files after build.
    makepkg -sic
}

# ----------------------------------------------------------------------------------

# Update git repos
update() {

    if [ -z "$(ls -A ${DUSDIR})" ]; then
        echo "Your local DUST directory is empty. Use Dust -m to migrate packages"
        echo
        exit 1
    fi

    cd "$DUSDIR" || exit

    echo "CHECKING FOR UPDATES"
    if [[ -z $1 ]]; then
        echo
        for DIR in ./*; do
            # Remove directory path, leaving only the name.
            # Then pass the package name to the update function
            do_update ${DIR:2}
            cd ..
        done
    else
        if [[ ! -d ${DUSDIR}/${1} ]]; then
            echo -e "${red}MISSING:${reset} ${PKG} not a package in ${DUSDIR}"
            echo
            exit 1
        fi
        echo
        do_update $1
    fi

    # Offer to install the package updates
    REMOVE_PKG=false
    offer_to_install
}

# ----------------------------------------------------------------------------------

# Perform the update routine
do_update() {
    local PKG
    PKG=$1

    if [[ ! -f ${DUSDIR}/${PKG}/.SRCINFO ]]; then
        echo -e "${red}ERROR:${reset} Can not resolve a non exiasting file .SRCINFO ${DUSDIR}/${PKG}"
        return 1
    fi

    # Get the version number of the currently installed package.
    local_pkgver=$(pacman -Q $PKG 2>/dev/null)

    # No version number? Package isn't installed
    if [[ "$?" -ne 0 ]]; then
        echo -e "${red}ERROR:${reset} ${PKG} is not installed but was requested for use."
        remove_pkgs $PKG
        return 1
    fi

    # Remove the package name, leaving only the version/release number
    local_pkgver=$(echo $local_pkgver | sed "s/${PKG} //")
    local_pkgver=$(echo $local_pkgver | sed "s/[ ]//")

    cd ${DUSDIR}/${PKG} || exit
    git pull >/dev/null 2>&1

    # Open .SRCINFO and get the version/release numbers
    # for comparison with the installed version
    pkgver=$(sed -n 's/pkgver[ ]*=//p'  .SRCINFO)
    pkgrel=$(sed -n 's/pkgrel[ ]*=//p'  .SRCINFO)

    # Kill stray spaces
    pkgver=$(echo $pkgver | sed "s/[ ]//g")
    pkgrel=$(echo $pkgrel | sed "s/[ ]//g")

    # Combine pkgver and pkgrel into the new full version number for comparison
    if [[ ! -z $pkgrel ]]; then
        new_pkgver="${pkgver}-${pkgrel}"
    else
        new_pkgver="${pkgver}"
    fi

    if [[ $(vercmp $new_pkgver $local_pkgver) -eq 1 ]]; then
        echo -e "${yellow}*UPDATE: ${PKG} ${pkgver}. Successfully downloaded build files.${reset}" 
        TO_INSTALL+=("$PKG")
    else
        echo -e "${green}CURRENT:${reset} ${PKG} is up to the dust list."
    fi
}

# ----------------------------------------------------------------------------------

# Verify that all dependencies for a remote DUS package are installed. 
verify_rdep() {
    validate_pkgname "$1"
    local PKG
    PKG=$1

    echo -e "VERIFYING DEPENDENCIES FOR ${cyan}${PKG}${reset}"
    echo

    # Verify whether the package is an DUS or official package
    curl_result=$(curl -fsSk "${DUS_INFO_URL}${PKG}")

    # Parse the result using the installed JSON parser
    if [[ $JSON_PARSER == 'jq' ]]; then
        json_result=$(echo "$curl_result" | jq -r '.results')
    else
        json_result=$(echo "$curl_result" | jshon -e results)
    fi

    # Did the package query return a valid result?
    if [[ $json_result == "[]" ]]; then
        echo -e "${red}ERROR: $PKG is not an DUS package${reset}"
        echo
        echo "This function only verifies dependencies for installed DUS packages"
        echo
        return 0
    fi

    # Get the package dependencies using installed json parser
    if [[ $JSON_PARSER == 'jq' ]]; then
        has_depends=$(echo "$curl_result" | jq -r '.results[0].Depends') 
    else
        has_depends=$(echo "$curl_result" | jshon -e results -e 0 -e Depends)
    fi

    # If there is a result, recurisvely call this function with the dependencies
    if [[ $has_depends != "[]" ]] && [[ $has_depends != null ]]; then

        if [[ $JSON_PARSER == 'jq' ]]; then
            dependencies=$(echo "$curl_result" | jq -r '.results[0].Depends[]') 
        else
            dependencies=$(echo "$curl_result" | jshon -e results -e 0 -e Depends -a -u)
        fi

        # Run through the dependencies
        for depend in $dependencies; do

            # Remove everything after >= in $depend
            # Some dependencies have minimum version requirements
            # which screws up the package name
            depend=$(echo $depend | sed "s/>=.*//")

            # Make sure the dependency is installed
            pacman -Q $depend  >/dev/null 2>&1

            if [[ "$?" -eq 0 ]]; then
                echo -e " ${green}INSTALLED:${reset} ${depend}"
            else
                echo -e " ${red}NOT INSTALLED:${reset} ${depend}"
            fi
        done
    else
        echo -e "${red}$PKG requires no dependencies${reset}"
    fi
    echo
}

# ----------------------------------------------------------------------------------

# Verify that all dependencies for a local DUS package are installed. This is a 
# helper function that is useful to run prior to installing any new updates
# in case a new package dependency was needed
verify_ldep() {
    validate_pkgname "$1"
    local depend
    local PKG
    PKG=$1

    # If the package isn't currently managed by Dust...
    if [[ ! -d ${DUSDIR}/${PKG} ]]; then

        # Is the package installed on the system?...
        pacman -Q $PKG  >/dev/null 2>&1

        if [[ "$?" -eq 0 ]]; then

            # Verify whether the package is an DUS or official package
            curl_result=$(curl -fsSk "${DUS_INFO_URL}${PKG}")

            # Parse the result using the installed JSON parser
            if [[ $JSON_PARSER == 'jq' ]]; then
                json_result=$(echo "$curl_result" | jq -r '.results')
            else
                json_result=$(echo "$curl_result" | jshon -e results)
            fi

            # Did the package query return a valid result?
            if [[ $json_result == "[]" ]]; then
                echo -e "${red}ERROR: $PKG is not an DUS package${reset}"
                echo
                echo "This function only verifies dependencies for installed DUS packages"
                echo
                exit 1
            else
                echo -e "${red}ERROR: $PKG is installed but not under the vision of the Dust System${reset}"
                echo
                echo -e "For migrating the packages to Dust run: ${cyan}Dust -m${reset}"
                echo
                exit 1
            fi
        else
            echo -e "${red}ERROR: ${PKG} is not installed on the base system.${reset}"
            echo
            echo "This function only verifies dependencies for installed packages"
            echo
            exit 1
        fi
    fi

    if [[ ! -f ${DUSDIR}/${PKG}/.SRCINFO ]]; then
        echo -e "${red}ERROR:${reset} .SRCINFO does not exist in ${DUSDIR}/${PKG}"
        echo
        exit 1
    fi

    echo -e "VERIFYING DEPENDENCIES FOR ${cyan}${PKG}${reset}"
    echo

    # Preserve the old input field separator
    OLDIFS=$IFS
    # Change the input field separator from a space to a null
    IFS=$'\n'

    # Read the .SRCINFO file line by line
    for line in `cat ${DUSDIR}/${PKG}/.SRCINFO `; do
        
        # Remove tabs and spaces
        line=$(echo $line | sed "s/[ \t]//g")

        # Ignore lines that don't list dependencies
        if [[ ${line:0:8} != "depends=" ]]; then
            continue
        fi

        # Remove "depends=" leaving only the package name
        depend=$(echo $line | sed "s/depends=//")

        # Remove everything after >= in $depend
        # Some dependencies have minimum version requirements
        # which screws up the package name
        depend=$(echo $depend | sed "s/>=.*//")        

        # Make sure the dependency is installed
        pacman -Q $depend  >/dev/null 2>&1

        if [[ "$?" -eq 0 ]]; then
            echo -e " ${green}INSTALLED:${reset} ${depend}"
        else
            echo -e " ${red}NOT INSTALLED:${reset} ${depend}"
        fi
    done

    # Restore input field separator
    IFS=$OLDIFS
    echo
}

# ----------------------------------------------------------------------------------

# DUS package name search
search() {
    local json_result
    local PKG
    PKG=$1

    # Fetch the JSON data associated with the package name search
    curl_result=$(curl -fsSk "${DUS_SRCH_URL}${PKG}")

    # Parse the result using the installed JSON parser
    if [[ $JSON_PARSER == 'jq' ]]; then
        json_result=$(echo "$curl_result" | jq -r '.results[] .Name')
    else
        json_result=$(echo "$curl_result" | jshon -e results -a -e Name -u)
    fi

    if [[ $json_result == "[]" ]] || [[ $json_result == null ]] || [[ -z $json_result ]]; then
        echo -e "${red}NO RESULTS:${reset} No results for \"${cyan}${PKG}${reset}\""
    else
        echo "SEARCH RESULTS"
        echo
        for res in $json_result; do
            # Capture the search term and surround it with %s
            # so we can use printf to replace with color variables
            res=$(echo "$res" | sed "s/\(.*\)\(${PKG}\)\(.*\)/\1%s\2%s\3/")

            printf -v res "$res" "${cyan}" "${reset}"

            echo -e " ${res}"
        done
    fi
    echo
}

# ----------------------------------------------------------------------------------

# Migrate all previously installed DUS packages to Dust
migrate() {
    
    # No argument, migrate all installed packages
    if [[ -z "$1" ]]; then
        echo "MIGRATING INSTALLED DUS PACKAGES TO Dust"
        echo
        IS_MIGRATING=true
        DUSPKGS=$(pacman -Qm | awk '{print $1}')
        for PKG in $DUSPKGS; do
            PKG=${PKG// /}
            download "$PKG"
        done
        IS_MIGRATING=false
        TO_INSTALL=()
        echo
        return 0
    fi

    local PKG
    PKG=$1

    # If the supplied package name is already managed by Dust...
    if [[ -d ${DUSDIR}/${PKG} ]]; then
        echo -e "${red}ERROR: ${PKG} has already been migrated${reset}"
        echo
        exit 1
    fi

    # Before migrating, let's make sure it's an installed DUS package
    pacman -Q $PKG  >/dev/null 2>&1

    # Package is installed
    if [[ "$?" -eq 0 ]]; then

        # Search for the package at DUS
        curl_result=$(curl -fsSk "${DUS_INFO_URL}${PKG}")

        # Parse the result using the installed JSON parser
        if [[ $JSON_PARSER == 'jq' ]]; then
            json_result=$(echo "$curl_result" | jq -r '.results')
        else
            json_result=$(echo "$curl_result" | jshon -e results)
        fi

        # Did the package query return a valid result?
        if [[ $json_result == "[]" ]]; then
            echo -e "${red}ERROR: $PKG is not an DUS package${reset}"
            echo
            echo "Only DUS packages can be migrated to Dust"
            echo
            exit 1
        fi
    else
        echo -e "${red}ERROR: ${PKG} is not installed on your system${reset}"
        echo
        echo "Only installed DUS packages can be migrated"
        echo
        exit 1
    fi

    echo "MIGRATING $1 TO Dust"
    echo
    IS_MIGRATING=true
    download "$1"
    IS_MIGRATING=false
    TO_INSTALL=()
    echo
}

# ----------------------------------------------------------------------------------

# Show locally installed packages
query() {
    echo "INSTALLED PACKAGES"
    echo
    cd $DUSDIR
    PKGS=$(ls)
    for P in $PKGS; do
        echo -e "  ${cyan}${P}${reset}"
    done
    echo
}

# ----------------------------------------------------------------------------------

# Remove both the local git repo and the package via pacman
remove() {
    cd "$DUSDIR" || exit
    PKG=$1
    if [[ ! -d ${DUSDIR}/${PKG} ]]; then
        echo -e "${red}ERROR:${reset} ${PKG} is not in the module list."
        echo
        exit 1
    fi

    echo -e "Proceed to remove the package/s ?"
    echo
    echo -e " ${cyan}${PKG}${reset}"
    echo
    read -p "ENTER [Y/n] " CONSENT

    if [[ $CONSENT =~ [y|Y] ]]; then
        sudo pacman -Rsc $PKG --noconfirm
        remove_pkgs $PKG
        echo
        echo -e "${red}REMOVED:${reset} ${PKG}"
    else
        echo
        echo "Exit Dust"
    fi
    echo
}

# ----------------------------------------------------------------------------------

# Remove a package folder from the local repo
remove_pkgs() {
    if [[ $REMOVE_PKG == false ]]; then
        return 0
    fi
    if [[ -z $1 ]]; then
        if [[ ${#TO_INSTALL[@]} -eq 0 ]]; then
            return 0
        fi
        for PKG in "${TO_INSTALL[@]}"; do
            rm -rf ${DUSDIR}/$PKG
        done
    else
        if [[ -d ${DUSDIR}/$1 ]]; then
            rm -rf ${DUSDIR}/$1
        fi
    fi
}

# ----------------------------------------------------------------------------------
#  BEGIN OUTPUT
# ----------------------------------------------------------------------------------

if [[ $SHOW_HEADING == true ]]; then
    clear
    heading purple "Dust $VERSION"
else
    echo
fi

# ----------------------------------------------------------------------------------

# DEPENDENCY CHECKS

# Is jq or jshon installed? 
if command -v jq &>/dev/null; then
    JSON_PARSER="jq"
elif command -v jshon &>/dev/null; then
    JSON_PARSER="jshon"
else
    echo -e "${red}DEPENDENCY ERROR:${reset} No JSON parser was known to Dust"
    echo
    echo "This script requires either jq or jshon"
    echo
    exit 1
fi

# Is curl installed?
if ! command -v curl &>/dev/null; then
    echo -e "${red}DEPENDENCY ERROR:${reset} Curl is not present on th base system"
    echo
    echo "This script requires Curl to retrieve search results and package info"
    echo
    exit 1
fi

# Is vercmp installed?
if ! command -v vercmp &>/dev/null; then
    echo -e "${red}DEPENDENCY ERROR:${reset} vercmp not installed"
    echo
    echo "This script requires vercmp to to compare version numbers"
    echo
    exit 1
fi

# ----------------------------------------------------------------------------------

# VALIDATE REQUEST

# No arguments, we show help
if [[ -z "$1" ]]; then
    help "error"
fi

CMD=$1          # first argument
CMD=${CMD,,}    # lowercase
CMD=${CMD//-/}  # remove dashes
CMD=${CMD// /}  # remove spaces

# Invalid arguments trigger help
if [[ $CMD =~ [^iusqrlmvh] ]]; then
    help "error"
fi

# Create the local DUS folder if it doesn't exist
if [[ ! -d "$DUSDIR" ]]; then
    mkdir -p "$DUSDIR"
fi

# ----------------------------------------------------------------------------------

# PROCESS REQUEST

shift
case "$CMD" in
    i)  install "$@" ;;
    u)  update "$@" ;;
    s)  search "$@" ;;
    q)  query "$@" ;;
    r)  remove "$@" ;;
    m)  migrate "$@" ;;
    vl) verify_ldep "$@";;
    vr) verify_rdep "$@";;
    h)  help ;;
esac
