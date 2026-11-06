#!/usr/bin/env bash

csvAwk='
function csvsplit(line, f,    n, i, c, field, inq) {
    n = 0; field = ""; inq = 0
    for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (inq) {
            if (c == "\"") {
                if (substr(line, i + 1, 1) == "\"") { field = field "\""; i++ }
                else inq = 0
            } else field = field c
        } else if (c == "\"") inq = 1
        else if (c == ",") { f[++n] = field; field = "" }
        else field = field c
    }
    f[++n] = field
    return n
}'

log(){
    echo "$@" >&3
}

fail(){
    echo "error: $*" >&3
    echo "error: $*"
}

setup_deps(){
    missing=""
    command -v curl >/dev/null 2>&1 || missing="$missing curl"
    command -v jq >/dev/null 2>&1 || missing="$missing jq"
    command -v html2text >/dev/null 2>&1 || missing="$missing html2text"
    command -v ss >/dev/null 2>&1 || missing="$missing iproute2"
    command -v ifconfig >/dev/null 2>&1 || missing="$missing net-tools"
    nc -h 2>&1 | grep -q OpenBSD || missing="$missing netcat-openbsd"

    if [ -n "$missing" ]; then
        if command -v apk >/dev/null 2>&1; then
            echo "Installing missing packages:$missing"
            for pkg in $missing; do
                apk add --no-cache "$pkg" >/dev/null 2>&1 
            done
            command -v ss >/dev/null 2>&1 || apk add --no-cache iproute2-ss >/dev/null 2>&1
        fi
    fi

    for tool in curl jq html2text; do
        command -v $tool >/dev/null 2>&1 
    done

    if ! python3 -c 'import matplotlib' >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            echo "Installing python3 py3-matplotlib (for population.png)"
            apk add --no-cache python3 py3-matplotlib >/dev/null 2>&1 
        fi
        python3 -c 'import matplotlib' >/dev/null 2>&1 
    fi
}


all_ips(){
    ifconfig 2>/dev/null | grep -oE 'inet (addr:)?[0-9]+(\.[0-9]+){3}' | sed 's/inet //; s/addr://'
}


get_ip(){
    all_ips | grep -v '^127\.' | head -n 1
}


listen_addrs(){
    ss -ltn 2>/dev/null | awk 'NR > 1 {print $4}'
}

wait_for(){
    until grep -q "$2" "$1" 2>/dev/null; do
        if ! kill -0 "$3" 2>/dev/null; then
            grep -q "$2" "$1" 2>/dev/null
            return
        fi
        sleep 0.05
    done
}

workDir=$(mktemp -d)
busyFlag="$workDir/busy" 

busy_listener(){

    addr=$1
    n=0
    while [ -f "$busyFlag" ]; do
        n=$((n+1))
        d="$workDir/busy-$addr-$n"
        mkdir "$d" && mkfifo "$d/in" "$d/out" && : > "$d/err"
        $ncBin -v -n -N -l "$addr" "$PORT" < "$d/out" > "$d/in" 2> "$d/err" &
        bncPid=$!
        exec 7> "$d/out"
        exec 8< "$d/in"

        #Waiting for a client or for the main request to finish
        until grep -q '^Connection received' "$d/err"; do
            [ -f "$busyFlag" ] || break
            kill -0 "$bncPid" 2>/dev/null || break
            sleep 0.1
        done

        if grep -q '^Connection received' "$d/err"; then
            line=$(grep -m1 '^Connection received' "$d/err")
            bIp=$(echo "$line" | awk '{print $4}')
            read -r -t 2 -u 8 bReq
            bReq=${bReq%$'\r'}
            owner=$(cat "$busyFlag" 2>/dev/null)
            echo "$line"
            if [ "$bIp" = "$owner" ]; then
                echo "error: server busy - your previous request from $bIp is still being processed, try again later" >&7
            else
                echo "error: server busy with another client, try again later" >&7
            fi
            exec 7>&- 8<&-
            #Giving nc enough time to flush the reply
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                kill -0 "$bncPid" 2>/dev/null || break
                sleep 0.2
            done
        elif [ -f "$busyFlag" ] && ! kill -0 "$bncPid" 2>/dev/null; then
            echo "warning: busy listener on $addr could not start: $(cat "$d/err")"
            exec 7>&- 8<&-
            rm -rf "$d"
            return
        else
            exec 7>&- 8<&-
        fi
        kill "$bncPid" 2>/dev/null
        wait "$bncPid" 2>/dev/null
        rm -rf "$d"
    done
}

start_busy(){
    echo "$1" > "$busyFlag"
    busyPids=""
    for addr in $allIps; do
        busy_listener "$addr" &
        busyPids="$busyPids $!"
    done
}

stop_busy(){
    rm -f "$busyFlag"
    for pid in $busyPids; do
        wait "$pid" 2>/dev/null
    done
    busyPids=""
}

# ----------------------------------------------------------

html_cells(){
    awk -v bs="$(printf '\b')" '{
        gsub("." bs, "")
        gsub(/\|/, "  ")
        gsub(/[*#]/, "")
        gsub(/\[[^]]*\]/, "  ")
        n = split($0, parts, /  +/)
        for (i = 1; i <= n; i++) {
            c = parts[i]
            gsub(/^ +| +$/, "", c)
            if (c != "" && c !~ /^[-=+_ ]+$/) print c
        }
    }' "$1"
}

#JSON escape a string: jq if present otherwise sed
json_str(){
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg v "$1" '$v'
    else
        printf '"%s"\n' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    fi
}

handle_assignment(){
    log "Downloading $assignmentUrl"
    if ! curl -fsSL --max-time 30 "$assignmentUrl" -o assignment.html; then
        fail "could not download the unit page ($assignmentUrl)"
        return
    fi

    html_cells assignment.txt > assignment.cells

    block=$(awk -v want="$ASSIGNMENT_NO" '
        /^Outcomes assessed/ {
            if (num != "" && ((want == "" && num + 0 > best + 0) || num == want)) {
                best = num; chosen = buf
            }
            buf = ""; num = ""; next
        }
        {
            buf = buf $0 "\n"
            if (num == "" && match($0, /^Assignment [0-9]+/)) {
                split(substr($0, RSTART, RLENGTH), t, " "); num = t[2]
            }
        }
        END { if (best == "") exit 1; printf "%s", chosen }' assignment.cells)
    if [ -z "$block" ]; then
        fail "could not find an 'Assignment N' assessment on the unit page"
        return
    fi

    joined=$(echo "$block" | tr '\n' ' ')
    title=$(echo "$block" | grep -oE '^Assignment [0-9]+' | head -n 1)

    typeName=$(echo "$block" | awk -v t="$title" '
        index($0, t) == 1 || / - / || /%/ || /^(LO[0-9]+ *)+$/ { next }
        /^(Week|Due date|Closing date|Formal exam|Multiple weeks)/ || /^[0-9]+ (weeks?|hours?)/ || /^AI / { next }
        { print; exit }')

    description=$(echo "$block" | awk -v t="$title" '
        found && / - / && $0 !~ /^(Due|Closing) date/ { print; exit }
        index($0, t) == 1 {
            found = 1
            rest = substr($0, length(t) + 2)
            if (rest ~ / - /) { print rest; exit }
        }' | sed 's/ [0-9]\{1,3\}%.*//')

    descPrefix=${description%% - *}
    topicFull=${description#* - }
    topic=${topicFull%% *}
    weight=$(echo "$joined" | grep -oE '[0-9]{1,3}%' | head -n 1)
    points=${weight%\%}

    due=$(echo "$joined" | grep -oE 'Due date *: *[0-9]{1,2} [A-Za-z]{3,9} [0-9]{4}( at [0-9]{1,2}:[0-9]{2})?' \
        | head -n 1 | sed 's/Due date *: *//')
    dueJson=$(echo "$due" | sed 's/ at / /')
    length=$(echo "$joined" | grep -oE '(^| )[0-9]+ weeks?( |$)' | head -n 1 | sed 's/^ *//; s/ *$//')
    ai=$(echo "$joined" | grep -oE 'AI [a-z]+' | head -n 1)

    if [ -z "$title" ] || [ -z "$topic" ] || [ "$topic" = "$description" ] || [ -z "$due" ] || [ -z "$points" ]; then
        fail "could not parse the assignment details (title='$title' topic='$topic' due='$due' points='$points')"
        return
    fi

    log "Assignment info:"

    log "$typeName / $title / $descPrefix - $weight / $topic / Due date: $due / $length / $ai"

    {
        echo "{"
        echo "    \"title\" : $(json_str "$title"),"
        echo "    \"topic\" : $(json_str "$topic"),"
        echo "    \"due_date\" : $(json_str "$dueJson"),"
        echo "    \"points\" : $points"
        echo "}"
    } > assignment.json
    if command -v jq >/dev/null 2>&1 && ! jq empty assignment.json 2>/dev/null; then
        fail "generated assignment.json is not valid JSON"
        return
    fi
    log "Created assignment.json, sending it to the client"
    cat assignment.json
}

# ----------------------------------------------------------

state_name(){
    case $1 in
        1) echo "NSW" ;; 2) echo "VIC" ;; 3) echo "QLD" ;; 4) echo "SA" ;;
        5) echo "WA" ;;  6) echo "TAS" ;; 7) echo "NT" ;;  8) echo "ACT" ;;
        9) echo "OT" ;;  *) echo "" ;;
    esac
}

handle_population(){
    log "Downloading $populationUrl"
    
    if ! curl -fsSL --max-time 30 "$populationUrl" -o population.csv; then
        fail "could not download the population CSV ($populationUrl)"
        return
    fi

    stateCode=$(echo "$populationUrl" | sed -n 's/.*STE_\([0-9][0-9]*\).*/\1/p')

    result=$(awk -v year="$YEAR" -v urlState="$(state_name "$stateCode")" "$csvAwk"'
        function commas(n,    s) {
            s = ""
            while (length(n) > 3) { s = "," substr(n, length(n) - 2) s; n = substr(n, 1, length(n) - 3) }
            return n s
        }
        { sub(/\r$/, "") }
        NR == 1 {
            n = csvsplit($0, h)
            for (i = 1; i <= n; i++) {
                low = tolower(h[i])
                if (low == "description") descCol = i
                if (low == "measure code") codeCol = i
                if (low == "parent description") parentCol = i
                if (low ~ /^(state|ste|state name|state code|region)/) stateCol = i
                if (h[i] ~ /^[0-9][0-9][0-9][0-9]$/) {
                    if (year == "latest" && h[i] + 0 > best + 0) { best = h[i]; yearCol = i }
                    if (h[i] == year) { best = h[i]; yearCol = i }
                }
            }
            if (!descCol) { print "ERR|no Description column in the CSV header"; exit }
            if (!yearCol) { print "ERR|no " year " column in the CSV header"; exit }
            if (!stateCol && urlState == "") { print "ERR|cannot tell which state this CSV is for"; exit }
            if (!stateCol && urlState != "NSW") { print "ERR|this CSV is for " urlState ", not NSW"; exit }
            next
        }
        {
            csvsplit($0, f)
            if (stateCol && f[stateCol] !~ /^(NSW|New South Wales|1)$/) next
            if (f[descCol] == "Estimated resident population (no.)") {
                found = 1
                if (f[yearCol] == "") { print "ERR|NSW row found but the " best " value is empty"; exit }
                print "OK|" best "|" commas(f[yearCol]) "|" (parentCol ? f[parentCol] : "")
                exit
            }
        }
        END { if (NR > 1 && !found) print "ERR|no NSW estimated resident population row in the CSV" }
    ' population.csv | head -n 1)

    case "$result" in
        OK*)
            popYear=$(echo "$result" | cut -d'|' -f2)
            popValue=$(echo "$result" | cut -d'|' -f3)
            popNote=$(echo "$result" | cut -d'|' -f4)
            log "NSW population ($popYear): $popValue  [$popNote]"
            ;;
        ERR*)
            fail "${result#ERR|}"
            return
            ;;
        *)
            fail "could not parse the population CSV"
            return
            ;;
    esac

    awk "$csvAwk"'
        { sub(/\r$/, "") }
        NR == 1 {
            n = csvsplit($0, h)
            for (i = 1; i <= n; i++) {
                if (tolower(h[i]) == "description") descCol = i
                if (h[i] ~ /^[0-9][0-9][0-9][0-9]$/) isYear[i] = 1
            }
            print "year,population"
            next
        }
        {
            csvsplit($0, f)
            if (f[descCol] != "Estimated resident population (no.)") next
            for (i = 1; i <= n; i++)
                if (isYear[i] && f[i] ~ /^[0-9]+$/) print h[i] "," f[i]
            exit
        }' population.csv > population_data.csv
    points=$(($(wc -l < population_data.csv) - 1))

    log "Read $points (year,population) pairs: $(tail -n +2 population_data.csv | tr '\n' ' ')"

    rm -f population.png
    if ! plotErr=$(python3 "$scriptDir/plot_population.py" population_data.csv population.png \
            "NSW estimated resident population (30 June)" 2>&1 >/dev/null); then
        fail "plotting failed: $plotErr"
        return
    fi

    log "Created population.png ($(wc -c < population.png) bytes), sending it to the client"
    cat population.png
}

case $# in
    0)run_server ;;
    1)if ! [ "$1" -ge 1 ] 2>/dev/null || [ "$1" -gt 65535 ]; then
        echo "usage: port must be a number between 1 and 65535"
        exit 1
      fi
      PORT=$1
      run_server ;;
    *)echo "usage: bash server.sh [port]"
      exit 1 ;;
esac