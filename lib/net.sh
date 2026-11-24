#!/usr/bin/env bash
# ==============================================================================
# NexusNode Network Utilities: 3-Tier SNI Scanner, Ports, Certs, CDN & Hopping
#   Tier 1: Same-subnet (/24) clean neighbor scan (DNS back-check + inst bonus)
#   Tier 2: Region-matched universities (edu) & research networks/RIRs (research)
#   Tier 3: Global non-Cloudflare open-source & public infrastructure (public)
# ==============================================================================

export NEXUS_SNI_MODE="${NEXUS_SNI_MODE:-auto}"       # auto | edu | neighbor
export NEXUS_SNI_REGION="${NEXUS_SNI_REGION:-auto}"   # auto | hk | jp | sg | tw | kr | us | eu | au | global | all
SNI_TOP_CANDIDATES=()
SNI_CURL_CAPS_READY=0
SNI_CURL_HAS_HTTP2=0
SNI_CURL_HAS_CURVES=0
SNI_CURL_HAS_TLSMAX=0
SNI_CURL_HAS_CERTINFO=0
SNI_CURL_OPENSSL_ENV=0

# Emergency zero-fork presets when container PID/RAM or curl TLS 1.3 is unavailable
STATIC_FALLBACK_SNI=(
    "www.cesnet.cz"
    "www.kernel.org"
    "www.apache.org"
    "www.surf.nl"
    "www.nic.cz"
)

# Curated non-Cloudflare seed pool: <category> <region> <hostname>
# Categories: edu (高校) | research (科研基地/教育骨干网/RIR/IXP) | public (开源与公共基建)
institutional_sni_catalog() {
    cat <<'EOF'
edu hk www.hku.hk
edu hk www.hkust.edu.hk
edu hk www.cityu.edu.hk
edu hk www.hkbu.edu.hk
research jp www.sinet.ad.jp
research jp www.nii.ac.jp
research jp www.jaxa.jp
edu jp www.kyushu-u.ac.jp
edu jp www.kyoto-u.ac.jp
edu jp www.titech.ac.jp
edu sg www.nus.edu.sg
edu sg www.smu.edu.sg
edu sg www.sutd.edu.sg
edu tw www.ncku.edu.tw
edu tw www.ncu.edu.tw
research tw www.twnic.tw
edu kr www.snu.ac.kr
edu us www.stanford.edu
edu us www.washington.edu
edu us www.ucla.edu
edu us www.cornell.edu
research us www.internet2.edu
research us www.ucar.edu
research us www.lacnic.net
edu eu www.ethz.ch
research eu www.cesnet.cz
research eu www.surf.nl
research eu www.nic.cz
research eu www.netnod.se
research eu www.ripe.net
research eu www.switch.ch
edu au www.waikato.ac.nz
edu au www.auckland.ac.nz
edu au www.canterbury.ac.nz
edu au www.sydney.edu.au
public global www.kernel.org
public global www.python.org
public global www.postgresql.org
public global deb.debian.org
public global www.openssl.org
public global www.isc.org
public global www.apache.org
public global files.pythonhosted.org
public global www.afrinic.net
EOF
}

is_port_in_use() {
    local port="$1"
    ss -tuln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
}

random_high_port() {
    local port attempts=0
    while (( attempts < 50 )); do
        port=$(( RANDOM % 50000 + 10000 ))
        if ! is_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
        ((attempts++))
    done
    ui_err "无法找到可用高位端口。"
    return 1
}

get_valid_port() {
    local input_port="${1:-}"
    input_port="$(echo "$input_port" | tr -d '[:space:]')"
    if [[ -z "$input_port" ]]; then
        random_high_port
        return $?
    fi
    if [[ ! "$input_port" =~ ^[0-9]+$ ]] || (( input_port < 1 || input_port > 65535 )); then
        ui_err "端口必须是 1-65535 之间的整数。"
        return 1
    fi
    if is_port_in_use "$input_port"; then
        ui_warn "端口 ${input_port} 当前已被占用（若为覆盖重装则继续）。"
    fi
    echo "$input_port"
}

get_cf_https_port() {
    local p
    for p in 443 8443 2053 2083 2087 2096; do
        if ! is_port_in_use "$p"; then
            echo "$p"
            return 0
        fi
    done
    echo "443"
}

# 0 = direct/grey cloud, 1 = CDN/orange cloud, 2 = unresolved
check_domain_direct_status() {
    local domain="$1"
    local pub_ip="$2"
    local resolved_ips
    resolved_ips="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    if [[ -z "$resolved_ips" ]]; then
        return 2
    fi
    if echo "$resolved_ips" | grep -qxF "$pub_ip"; then
        return 0
    fi
    return 1
}

normalize_sni_host() {
    local host="${1:-}"
    host="$(printf '%s' "$host" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
    host="${host#https://}"
    host="${host#http://}"
    host="${host%%[/?#]*}"
    host="${host%:443}"
    host="${host%.}"
    printf '%s\n' "$host"
}

validate_sni() {
    local sni
    sni="$(normalize_sni_host "${1:-}")"
    if [[ -z "$sni" || ! "$sni" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ || "$sni" =~ ^[0-9.]+$ ]]; then
        ui_err "非法域名格式: ${1:-}"
        return 1
    fi
    echo "$sni"
}

# Filter out Apple, CDN, dynamic DNS, punycode, and placeholder domains for Reality SNI
is_allowed_reality_sni() {
    local host
    host="$(normalize_sni_host "${1:-}")"
    [[ -z "$host" || "${#host}" -gt 253 ]] && return 1
    [[ ! "$host" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] && return 1
    [[ "$host" =~ ^[0-9.]+$ ]] && return 1
    [[ "$host" == *xn--* ]] && return 1
    case "$host" in
        apple.com|*.apple.com|icloud.com|*.icloud.com|mzstatic.com|*.mzstatic.com) return 1 ;;
        localhost|*.localhost|*.local|*.invalid|*.test|*.example|*.internal|*.lan) return 1 ;;
        *cloudflare*|*amazonaws*|*cloudfront*|*fastly*|*akamai*|*azureedge*|*trafficmanager*) return 1 ;;
        *.workers.dev|*.pages.dev|*.vercel.app|*.netlify.app|*.herokuapp.com|*.github.io) return 1 ;;
        *.nip.io|*.sslip.io|*.xip.io|*.duckdns.org|*.ddns.net|*.no-ip.*|*.synology.me) return 1 ;;
    esac
    return 0
}

valid_sni_region() {
    case "${1:-}" in
        auto|all|global|hk|jp|sg|tw|kr|us|eu|au) return 0 ;;
        *) return 1 ;;
    esac
}

valid_sni_mode() {
    case "${1:-}" in
        auto|edu|inst|neighbor) return 0 ;;
        *) return 1 ;;
    esac
}

sni_region_from_country() {
    local cc
    cc="$(printf '%s' "${1:-}" | tr 'a-z' 'A-Z')"
    case "$cc" in
        HK|MO) echo "hk" ;;
        JP) echo "jp" ;;
        SG|MY|TH|ID|PH|VN|KH|LA|MM|BN|TL) echo "sg" ;;
        TW) echo "tw" ;;
        KR) echo "kr" ;;
        AU|NZ) echo "au" ;;
        US|CA|MX) echo "us" ;;
        CN) echo "hk" ;;
        AD|AL|AT|BA|BE|BG|BY|CH|CY|CZ|DE|DK|EE|ES|FI|FR|GB|GR|HR|HU|IE|IS|IT|LI|LT|LU|LV|MC|MD|ME|MK|MT|NL|NO|PL|PT|RO|RS|SE|SI|SK|SM|UA|VA|XK) echo "eu" ;;
        *) echo "global" ;;
    esac
}

detect_sni_region() {
    local raw cc=""
    raw=$(curl -q --noproxy '*' -fsSL --connect-timeout 2 --max-time 3 'https://ipwho.is/?fields=country_code' 2>/dev/null || true)
    if [[ "$raw" =~ \"country_code\"[[:space:]]*:[[:space:]]*\"([A-Za-z]{2})\" ]]; then
        cc="${BASH_REMATCH[1]}"
    fi
    if [[ -z "$cc" ]]; then
        raw=$(curl -q --noproxy '*' -fsSL --connect-timeout 2 --max-time 3 'https://api.country.is' 2>/dev/null || true)
        if [[ "$raw" =~ \"country\"[[:space:]]*:[[:space:]]*\"([A-Za-z]{2})\" ]]; then
            cc="${BASH_REMATCH[1]}"
        fi
    fi
    if [[ -z "$cc" ]]; then
        raw=$(curl -q --noproxy '*' -fsSL --connect-timeout 2 --max-time 3 'https://ipinfo.io/country' 2>/dev/null | tr -d '[:space:]' || true)
        [[ "$raw" =~ ^[A-Za-z]{2}$ ]] && cc="$raw"
    fi
    [[ -n "$cc" ]] || return 1
    sni_region_from_country "$cc"
}

# Compute container-safe worker concurrency using cgroup v1/v2 & MemAvailable
get_safe_sni_jobs() {
    local desired="${1:-8}"
    local jobs="$desired"
    local key val unit avail_bytes=-1 limit usage free

    if [[ -r /proc/meminfo ]]; then
        while read -r key val unit _; do
            if [[ "$key" == "MemAvailable:" && "$val" =~ ^[0-9]+$ ]]; then
                avail_bytes=$(( 10#$val * 1024 ))
                break
            fi
        done < /proc/meminfo
    fi

    if [[ -r /sys/fs/cgroup/memory.max && -r /sys/fs/cgroup/memory.current ]]; then
        read -r limit < /sys/fs/cgroup/memory.max || limit=""
        read -r usage < /sys/fs/cgroup/memory.current || usage=""
        if [[ "$limit" =~ ^[0-9]+$ && "$usage" =~ ^[0-9]+$ ]]; then
            free=$(( 10#$limit - 10#$usage ))
            (( free < 0 )) && free=0
            if (( avail_bytes < 0 || free < avail_bytes )); then
                avail_bytes="$free"
            fi
        fi
    fi

    if (( avail_bytes >= 0 )); then
        local mem_jobs=$(( (avail_bytes - 16 * 1024 * 1024) / (20 * 1024 * 1024) ))
        (( mem_jobs < 0 )) && mem_jobs=0
        (( mem_jobs < jobs )) && jobs="$mem_jobs"
    fi

    if [[ -r /sys/fs/cgroup/pids.max && -r /sys/fs/cgroup/pids.current ]]; then
        read -r limit < /sys/fs/cgroup/pids.max || limit=""
        read -r usage < /sys/fs/cgroup/pids.current || usage=""
        if [[ "$limit" =~ ^[0-9]+$ && "$usage" =~ ^[0-9]+$ ]]; then
            free=$(( 10#$limit - 10#$usage ))
            if (( free < 4 )); then
                echo 0
                return 1
            fi
            local pid_jobs=$(( (free - 4) / 3 ))
            (( pid_jobs < 1 )) && pid_jobs=1
            (( pid_jobs < jobs )) && jobs="$pid_jobs"
        fi
    fi

    if (( jobs < 1 )); then
        echo 0
        return 1
    fi
    echo "$jobs"
}

detect_sni_curl_caps() {
    [[ "$SNI_CURL_CAPS_READY" -eq 1 ]] && return 0
    SNI_CURL_CAPS_READY=1
    command -v curl >/dev/null 2>&1 || return 1

    local ver_out first_line features_line help_out ver_str major minor is_openssl_like=0
    ver_out="$(CURL_SSL_BACKEND=openssl curl -q --version 2>/dev/null || curl -q --version 2>/dev/null || true)"
    first_line="$(printf '%s\n' "$ver_out" | head -n 1)"
    features_line="$(printf '%s\n' "$ver_out" | grep -E '^Features:' || true)"

    if [[ "$first_line" =~ (OpenSSL|BoringSSL|LibreSSL|quictls) ]]; then
        is_openssl_like=1
        CURL_SSL_BACKEND=openssl curl -q --version >/dev/null 2>&1 && SNI_CURL_OPENSSL_ENV=1
    fi

    [[ " $features_line " == *" HTTP2 "* ]] && SNI_CURL_HAS_HTTP2=1

    ver_str="$(printf '%s\n' "$first_line" | awk '{print $2}')"
    IFS=. read -r major minor _ <<< "$ver_str"
    if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
        if (( major > 7 || (major == 7 && minor >= 88) )); then
            SNI_CURL_HAS_CERTINFO=1
        fi
    fi

    if [[ "$is_openssl_like" -eq 1 ]]; then
        help_out="$(curl --help tls 2>&1 || curl --help all 2>&1 || curl --help 2>&1 || true)"
        [[ "$help_out" == *"--curves"* ]] && SNI_CURL_HAS_CURVES=1
        [[ "$help_out" == *"--tls-max"* ]] && SNI_CURL_HAS_TLSMAX=1
    fi

    if [[ "$SNI_CURL_HAS_HTTP2" -eq 0 ]] && ! command -v openssl >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Probe target domain for TLS 1.3 + X25519 + CA Verify + HTTP/2 + Short Chain + Non-Cloudflare
# Output on success: "<best_ms>\t<chain_len>"
probe_sni_target() {
    local host="$1"
    local samples="${2:-2}"
    local limit="${3:-3}"
    is_allowed_reality_sni "$host" || return 1
    detect_sni_curl_caps || return 1

    local round out meta verify http_ver elapsed chain best_ms=2147483647 best_chain=0 cur_ms hdr_lower

    # Fallback path when libcurl lacks HTTP2 feature (uses openssl s_client for TLS1.3+H2+X25519 + curl for timing/CA/CDN)
    if [[ "$SNI_CURL_HAS_HTTP2" -eq 0 ]]; then
        local tls_out
        tls_out=$(timeout "$limit" openssl s_client -connect "${host}:443" -servername "$host" -tls1_3 -alpn h2 </dev/null 2>/dev/null | tr -d '\0' || true)
        [[ "$tls_out" == *"TLSv1.3"* && "$tls_out" == *"ALPN protocol: h2"* ]] || return 1
        printf '%s' "$tls_out" | grep -qi "X25519" || return 1
        best_chain="$(printf '%s\n' "$tls_out" | awk '/^Certificate chain/,/^---/ {if ($1 ~ /^[0-9]+$/) c++} END {print c+0}')"

        local fmt_fb=$'\n__NX_META__\t%{ssl_verify_result}\t%{time_appconnect}'
        for (( round = 0; round < samples; round++ )); do
            out=$(LC_ALL=C curl -q --noproxy '*' -sS --head --connect-timeout "$limit" --max-time "$limit" \
                --write-out "$fmt_fb" "https://${host}/" 2>/dev/null) || {
                (( round > 0 )) && continue || return 1
            }
            meta="$(printf '%s\n' "$out" | tr -d '\r' | awk -F'\t' '$1 == "__NX_META__" {print $2 "\t" $3}' | tail -n 1)"
            IFS=$'\t' read -r verify elapsed <<< "$meta"
            if [[ "$verify" != "0" || ! "$elapsed" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                (( round > 0 )) && continue || return 1
            fi
            hdr_lower="$(printf '%s\n' "$out" | tr -d '\r' | tr 'A-Z' 'a-z')"
            if printf '%s\n' "$hdr_lower" | grep -qE '^(cf-ray:|server:[[:space:]]*(cloudflare|akamaighost|akamai|fastly))'; then
                return 1
            fi
            cur_ms="$(awk -v t="$elapsed" 'BEGIN { m = int(t * 1000 + 0.5); if (m < 1) m = 1; print m }')"
            (( cur_ms < best_ms )) && best_ms="$cur_ms"
        done
        (( best_ms < 2147483647 )) || return 1
        printf '%s\t%s\n' "$best_ms" "$best_chain"
        return 0
    fi

    local -a extra_args=(--http2 --tlsv1.3)
    [[ "$SNI_CURL_HAS_TLSMAX" -eq 1 ]] && extra_args+=(--tls-max 1.3)
    [[ "$SNI_CURL_HAS_CURVES" -eq 1 ]] && extra_args+=(--curves X25519)

    local fmt=$'\n__NX_META__\t%{ssl_verify_result}\t%{http_version}\t%{time_appconnect}\t0'
    [[ "$SNI_CURL_HAS_CERTINFO" -eq 1 ]] && fmt=$'\n__NX_META__\t%{ssl_verify_result}\t%{http_version}\t%{time_appconnect}\t%{num_certs}'

    for (( round = 0; round < samples; round++ )); do
        if [[ "$SNI_CURL_OPENSSL_ENV" -eq 1 ]]; then
            out=$(LC_ALL=C CURL_SSL_BACKEND=openssl curl -q --noproxy '*' -sS --head \
                --connect-timeout "$limit" --max-time "$limit" "${extra_args[@]}" \
                --write-out "$fmt" "https://${host}/" 2>/dev/null) || {
                (( round > 0 )) && continue || return 1
            }
        else
            out=$(LC_ALL=C curl -q --noproxy '*' -sS --head \
                --connect-timeout "$limit" --max-time "$limit" "${extra_args[@]}" \
                --write-out "$fmt" "https://${host}/" 2>/dev/null) || {
                (( round > 0 )) && continue || return 1
            }
        fi

        meta="$(printf '%s\n' "$out" | tr -d '\r' | awk -F'\t' '$1 == "__NX_META__" {print $2 "\t" $3 "\t" $4 "\t" $5}' | tail -n 1)"
        IFS=$'\t' read -r verify http_ver elapsed chain <<< "$meta"
        if [[ "$verify" != "0" || "$http_ver" != "2" || ! "$elapsed" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            (( round > 0 )) && continue || return 1
        fi
        [[ "$chain" =~ ^[0-9]+$ ]] || chain=0

        # Reject domains that drifted behind Cloudflare / Akamai / Fastly CDN
        hdr_lower="$(printf '%s\n' "$out" | tr -d '\r' | tr 'A-Z' 'a-z')"
        if printf '%s\n' "$hdr_lower" | grep -qE '^(cf-ray:|server:[[:space:]]*(cloudflare|akamaighost|akamai|fastly))'; then
            return 1
        fi

        cur_ms="$(awk -v t="$elapsed" 'BEGIN { m = int(t * 1000 + 0.5); if (m < 1) m = 1; print m }')"
        (( cur_ms < best_ms )) && best_ms="$cur_ms"
        (( chain > best_chain )) && best_chain="$chain"
    done

    (( best_ms < 2147483647 )) || return 1
    printf '%s\t%s\n' "$best_ms" "$best_chain"
}

# Verify that every IPv4 A record of $domain resolves strictly within $prefix.0/24
domain_in_same_slash24() {
    local domain="$1"
    local prefix="$2"
    local ips ip count=0
    ips="$(getent ahosts "$domain" 2>/dev/null | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1}' | sort -u || true)"
    [[ -z "$ips" ]] && return 1
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        [[ "$ip" == "${prefix}."* ]] || return 1
        ((count++))
    done <<< "$ips"
    (( count > 0 ))
}

# Classify neighbor SAN domain quality: 0 = academic/public inst, 1 = clean root/www, 2 = clean 3-label
classify_neighbor_domain() {
    local dom="$1"
    # Reject suspicious random/numeric hostnames (e.g. panel/proxy subdomains)
    [[ "$dom" =~ [0-9]{4,} ]] && return 1
    if [[ "$dom" =~ \.(edu|ac|gov|mil|org)(\.[a-z]{2,3})?$ || "$dom" =~ \.(ad\.jp|re\.kr|or\.jp|or\.kr|go\.jp)$ ]]; then
        printf '0\t同段机构\n'
        return 0
    fi
    local dots="${dom//[^.]/}"
    local depth="${#dots}"
    if (( depth == 1 )) || [[ "$dom" =~ ^www\.[^.]+\.[^.]+(\.[a-z]{2,3})?$ ]]; then
        printf '1\t同网段\n'
        return 0
    elif (( depth == 2 )); then
        printf '2\t同网段\n'
        return 0
    fi
    return 1
}

# Tier 1: Scan nearby /24 neighbor IPs in safe batches for clean TLS 1.3 + X25519 + H2 domains
# Outputs sorted lines: "<ms>\t<domain>\t<chain>\t<tag>"
scan_neighbor_sni() {
    local pub_ip="$1"
    [[ ! "$pub_ip" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] && return 1
    local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}" self_last="${BASH_REMATCH[4]}"
    # Skip private, loopback, link-local, and CGNAT IPv4 ranges
    if (( o1 == 10 || o1 == 127 || (o1 == 192 && o2 == 168) || (o1 == 172 && o2 >= 16 && o2 <= 31) || (o1 == 100 && o2 >= 64 && o2 <= 127) || (o1 == 169 && o2 == 254) )); then
        return 1
    fi

    local jobs
    jobs="$(get_safe_sni_jobs 16)" || return 1
    local prefix="${o1}.${o2}.${o3}"
    local tmp_dir="/tmp/nexus_nb_$$"
    mkdir -p "$tmp_dir"

    # Order neighbor offsets outward from self_last (±24 IPs, closest sub-allocation first)
    local -a targets=()
    local delta lo hi
    for (( delta = 1; delta <= 24; delta++ )); do
        lo=$(( self_last - delta ))
        hi=$(( self_last + delta ))
        (( lo >= 1 )) && targets+=("$lo")
        (( hi <= 254 )) && targets+=("$hi")
    done

    local idx=0 total="${#targets[@]}" slot last hit_count=0
    local -a pids=()
    while (( idx < total )); do
        pids=()
        for (( slot = 0; slot < jobs && idx < total; slot++, idx++ )); do
            last="${targets[idx]}"
            (
                local ip="${prefix}.${last}"
                local tls_out san_list cand cls inst_tier tag probe_res ms chain chain_tier
                tls_out=$(timeout 1.0 openssl s_client -connect "${ip}:443" -tls1_3 -alpn h2 </dev/null 2>/dev/null | tr -d '\0' || true)
                if [[ "$tls_out" == *"TLSv1.3"* && "$tls_out" == *"ALPN protocol: h2"* ]] && printf '%s' "$tls_out" | grep -qi "X25519"; then
                    san_list=$(printf '%s\n' "$tls_out" | openssl x509 -noout -ext subjectAltName 2>/dev/null \
                        | tr ',' '\n' | sed -n 's/.*DNS:\([^ *][^ ]*\).*/\1/p' | head -n 3 || true)
                    while IFS= read -r cand; do
                        cand="$(normalize_sni_host "$cand")"
                        [[ -z "$cand" ]] && continue
                        is_allowed_reality_sni "$cand" || continue
                        cls="$(classify_neighbor_domain "$cand")" || continue
                        domain_in_same_slash24 "$cand" "$prefix" || continue
                        probe_res="$(probe_sni_target "$cand" 1 2)" || continue
                        IFS=$'\t' read -r inst_tier tag <<< "$cls"
                        IFS=$'\t' read -r ms chain <<< "$probe_res"
                        chain_tier=0
                        (( chain > 3 )) && chain_tier=2
                        (( chain == 0 )) && chain_tier=1
                        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$chain_tier" "$inst_tier" "$ms" "$chain" "$cand" "$tag" > "${tmp_dir}/${last}"
                        break
                    done <<< "$san_list"
                fi
            ) &
            pids+=("$!")
        done
        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
        local -a found_nb=("${tmp_dir}"/*)
        if [[ -e "${found_nb[0]}" ]]; then
            hit_count="${#found_nb[@]}"
        else
            hit_count=0
        fi
        (( hit_count >= 3 )) && break
    done

    local results=""
    local -a nb_files=("${tmp_dir}"/*)
    if [[ -e "${nb_files[0]}" ]]; then
        results=$(LC_ALL=C sort -t$'\t' -k1,1n -k2,2n -k3,3n "${nb_files[@]}" \
            | awk -F'\t' '!seen[$5]++ {print $3 "\t" $5 "\t" $4 "\t" $6}')
    fi
    rm -rf "$tmp_dir"
    [[ -n "$results" ]] || return 1
    printf '%s\n' "$results"
}

# Tier 2 & 3: Region-matched Universities / Research Backbones / Global Public Infra
# Outputs sorted lines: "<ms>\t<domain>\t<chain>\t<tag>"
scan_institutional_sni() {
    local region="${1:-auto}"
    local jobs
    jobs="$(get_safe_sni_jobs 8)" || return 1
    detect_sni_curl_caps || return 1

    if [[ "$region" == "auto" ]]; then
        region="$(detect_sni_region || echo "all")"
    fi
    valid_sni_region "$region" || region="all"
    local reg_upper
    reg_upper="$(printf '%s' "$region" | tr 'a-z' 'A-Z')"

    # Build candidate records: "<reg_prio>\t<cat_prio>\t<tag>\t<host>"
    local -a entries=()
    local cat cand_reg host reg_prio cat_prio tag c_upper
    while read -r cat cand_reg host; do
        [[ -z "$host" ]] && continue
        c_upper="$(printf '%s' "$cand_reg" | tr 'a-z' 'A-Z')"
        cat_prio=0
        [[ "$cat" == "public" ]] && cat_prio=1

        if [[ "$region" == "all" ]]; then
            reg_prio=0
            [[ "$cand_reg" == "global" ]] && reg_prio=1
        elif [[ "$region" == "global" ]]; then
            [[ "$cand_reg" == "global" ]] || continue
            reg_prio=0
        elif [[ "$cand_reg" == "$region" ]]; then
            reg_prio=0
        elif [[ "$region" == "kr" && "$cand_reg" == "jp" && "$cat" == "research" ]]; then
            reg_prio=1
        elif [[ "$cand_reg" == "global" ]]; then
            reg_prio=2
        else
            continue
        fi

        case "$cat" in
            edu)      tag="同区高校·${c_upper}" ;;
            research) tag="科研机构·${c_upper}" ;;
            *)        tag="公共基建" ;;
        esac
        [[ "$region" == "kr" && "$cand_reg" == "jp" ]] && tag="邻近科研·JP"
        entries+=("${reg_prio}"$'\t'"${cat_prio}"$'\t'"${tag}"$'\t'"${host}")
    done < <(institutional_sni_catalog)

    [[ "${#entries[@]}" -gt 0 ]] || return 1

    local tmp_dir="/tmp/nexus_inst_$$"
    mkdir -p "$tmp_dir"

    local idx=0 total="${#entries[@]}" slot
    local -a pids=() deadlines=()
    local samples=2 timeout_sec=3
    while (( idx < total )); do
        pids=()
        deadlines=()
        for (( slot = 0; slot < jobs && idx < total; slot++, idx++ )); do
            local item="${entries[idx]}"
            local out_file="${tmp_dir}/res_${idx}"
            (
                local r_prio c_prio s_tag s_host probe_out ms chain chain_tier
                IFS=$'\t' read -r r_prio c_prio s_tag s_host <<< "$item"
                if probe_out="$(probe_sni_target "$s_host" "$samples" "$timeout_sec")"; then
                    IFS=$'\t' read -r ms chain <<< "$probe_out"
                    chain_tier=0
                    (( chain > 3 )) && chain_tier=2
                    (( chain == 0 )) && chain_tier=1
                    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                        "$chain_tier" "$r_prio" "$c_prio" "$ms" "$chain" "$s_host" "$s_tag" > "$out_file"
                fi
            ) &
            pids+=("$!")
            deadlines+=("$(( SECONDS + samples * timeout_sec + 3 ))")
        done

        local pending="${#pids[@]}" s wpid
        while (( pending > 0 )); do
            for (( s = 0; s < ${#pids[@]}; s++ )); do
                wpid="${pids[s]}"
                [[ -z "$wpid" ]] && continue
                if ! kill -0 "$wpid" 2>/dev/null; then
                    wait "$wpid" 2>/dev/null || true
                    pids[s]=""
                    ((pending--))
                elif (( SECONDS >= deadlines[s] )); then
                    kill -TERM "$wpid" 2>/dev/null || true
                    sleep 0.1
                    kill -KILL "$wpid" 2>/dev/null || true
                    wait "$wpid" 2>/dev/null || true
                    pids[s]=""
                    ((pending--))
                fi
            done
            (( pending > 0 )) && sleep 0.08
        done
    done

    local results=""
    local -a inst_files=("${tmp_dir}"/res_*)
    if [[ -e "${inst_files[0]}" ]]; then
        results=$(LC_ALL=C sort -t$'\t' -k1,1n -k2,2n -k3,3n -k4,4n -k6,6 "${inst_files[@]}" \
            | awk -F'\t' '!seen[$6]++ {print $4 "\t" $6 "\t" $5 "\t" $7}')
    fi
    rm -rf "$tmp_dir"
    [[ -n "$results" ]] || return 1
    printf '%s\n' "$results"
}

# Benchmark SNI: 3-tier waterfall (Same-Subnet /24 -> Regional Edu/Research -> Global Public Infra)
benchmark_sni() {
    local __out_var="$1"
    local mode="${2:-${NEXUS_SNI_MODE:-auto}}"
    local region="${3:-${NEXUS_SNI_REGION:-auto}}"
    valid_sni_mode "$mode" || mode="auto"
    valid_sni_region "$region" || region="auto"

    local best_domain="${STATIC_FALLBACK_SNI[0]}"
    local best_time="--"
    local best_chain="0"
    local source_tag="静态预设兜底"
    local ranked_lines=""
    SNI_TOP_CANDIDATES=()

    tput civis 2>/dev/null || true

    # Tier 1: Same-subnet (/24) clean neighbor scan (unless mode is edu/inst)
    if [[ "$mode" != "edu" && "$mode" != "inst" ]]; then
        local pub_ip=""
        pub_ip=$(get_public_ip 2>/dev/null || true)
        if [[ "$pub_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            printf "${C_CLEAR_LINE}${C_CYAN}⠋${C_RESET} 正在扫描同网段(/24)干净伪装域名..."
            ranked_lines="$(scan_neighbor_sni "$pub_ip" || true)"
        fi
    fi

    # Tier 2 & 3: Regional Universities / Research Bases + Global Public Infra
    if [[ -z "$ranked_lines" ]]; then
        local resolved_reg="$region"
        if [[ "$resolved_reg" == "auto" ]]; then
            printf "${C_CLEAR_LINE}${C_CYAN}⠋${C_RESET} 正在识别出口地区并匹配高校/科研基地种子库..."
            resolved_reg="$(detect_sni_region || echo "all")"
        fi
        local reg_label
        reg_label="$(printf '%s' "$resolved_reg" | tr 'a-z' 'A-Z')"
        [[ "$resolved_reg" == "all" || "$resolved_reg" == "global" ]] && reg_label="全球"
        printf "${C_CLEAR_LINE}${C_CYAN}⠋${C_RESET} 正在优选 %s 高校、科研基地与公共机构域名 (TLS1.3+X25519+H2)..." "$reg_label"
        ranked_lines="$(scan_institutional_sni "$resolved_reg" || true)"
    fi

    tput cnorm 2>/dev/null || true

    if [[ -n "$ranked_lines" ]]; then
        local first_line line m d c t
        first_line="$(printf '%s\n' "$ranked_lines" | head -n 1)"
        IFS=$'\t' read -r best_time best_domain best_chain source_tag <<< "$first_line"
        while IFS=$'\t' read -r m d c t; do
            [[ -n "$d" ]] && SNI_TOP_CANDIDATES+=("$d")
            (( ${#SNI_TOP_CANDIDATES[@]} >= 5 )) && break
        done <<< "$ranked_lines"
    else
        SNI_TOP_CANDIDATES=("${STATIC_FALLBACK_SNI[@]}")
    fi

    local chain_badge=""
    [[ "$best_chain" =~ ^[1-9][0-9]*$ ]] && chain_badge=" · 链${best_chain}层"
    local time_badge="${best_time}ms"
    [[ "$best_time" == "--" ]] && time_badge="未测速"

    printf "${C_CLEAR_LINE}${C_GREEN}✔${C_RESET} 最优 SNI 伪装域名: ${C_BOLD}%s${C_RESET} ${C_GRAY}(%s · %s%s)${C_RESET}\n" \
        "$best_domain" "$source_tag" "$time_badge" "$chain_badge"
    eval "$__out_var=\"\$best_domain\""
}

# Interactive/Non-interactive SNI selector with candidate shortcuts & edu rescan
prompt_camouflage_sni() {
    local __dest_var="$1"
    local strict_reality="${2:-1}"
    local current_sni=""

    benchmark_sni current_sni

    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        while true; do
            if (( ${#SNI_TOP_CANDIDATES[@]} > 1 )); then
                local idx=1 hint_line="" cand
                for cand in "${SNI_TOP_CANDIDATES[@]}"; do
                    hint_line+="[${idx}] ${cand}  "
                    ((idx++))
                    (( idx > 4 )) && break
                done
                printf "  ${C_GRAY}候选编号: %s(输 edu 仅扫高校/科研)${C_RESET}\n" "$hint_line"
            fi

            local user_pick=""
            ui_ask "确认或修改伪装 SNI (回车默认 / 填编号 / 输 edu / 手输域名)" "$current_sni" user_pick
            user_pick="$(printf '%s' "$user_pick" | tr -d '[:space:]')"

            if [[ "$user_pick" == "edu" || "$user_pick" == "inst" ]]; then
                benchmark_sni current_sni "edu"
                continue
            fi

            if [[ "$user_pick" =~ ^[1-5]$ ]] && (( user_pick <= ${#SNI_TOP_CANDIDATES[@]} )); then
                current_sni="${SNI_TOP_CANDIDATES[$((user_pick - 1))]}"
                ui_ok "已选择候选 [${user_pick}]: ${current_sni}"
            else
                current_sni="$(normalize_sni_host "$user_pick")"
            fi

            if [[ "$strict_reality" -eq 1 ]] && ! is_allowed_reality_sni "$current_sni"; then
                ui_warn "该域名格式无效，或属于不推荐用于 Reality 的 Apple/CDN/动态域名: ${current_sni}"
                current_sni="${SNI_TOP_CANDIDATES[0]:-${STATIC_FALLBACK_SNI[0]}}"
                continue
            fi

            if validate_sni "$current_sni" >/dev/null; then
                break
            fi
        done
    fi

    eval "$__dest_var=\"\$current_sni\""
}

generate_self_signed_cert() {
    local cert_dir="$1"
    local domain="$2"
    local pub_ip="${3:-}"
    local san="DNS:${domain}"
    [[ -n "$pub_ip" && "$pub_ip" != *:* ]] && san="${san},IP:${pub_ip}"
    mkdir -p "$cert_dir"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -nodes -days 365 \
        -keyout "${cert_dir}/key.pem" \
        -out "${cert_dir}/cert.pem" \
        -subj "/CN=${domain}" \
        -addext "subjectAltName=${san}" >/dev/null 2>&1
    chown -R "$NEXUS_USER":"$NEXUS_USER" "$cert_dir" 2>/dev/null || true
}

issue_acme_cert() {
    local cert_dir="$1"
    local domain="$2"

    if [[ -s "${cert_dir}/cert.pem" && -s "${cert_dir}/key.pem" ]]; then
        ui_ok "检测到 ${domain} 已有 Let's Encrypt 正式证书，直接复用。"
        return 0
    fi

    if is_port_in_use 80; then
        ui_err "80 端口已被占用，无法使用 acme.sh standalone 模式申请证书。"
        return 1
    fi

    if ! command -v socat >/dev/null 2>&1; then
        case "$PKG_MGR" in
            apt) run_step "安装证书申请依赖 socat" "export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a && apt-get install -y -qq socat cron" ;;
            dnf|yum) run_step "安装证书申请依赖 socat" "$PKG_MGR install -y -q socat cronie" ;;
            apk) run_step "安装证书申请依赖 socat" "apk add --no-cache socat" ;;
        esac
    fi

    local acme_bin="/root/.acme.sh/acme.sh"
    if [[ ! -x "$acme_bin" ]]; then
        run_step "安装 acme.sh 证书签发客户端" "curl -fsSL --connect-timeout 10 --max-time 45 https://get.acme.sh | sh -s email=nexus@${domain}" || return 1
    fi

    open_firewall_port 80 "tcp"
    "$acme_bin" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

    local acme_rc=0
    run_step "向 Let's Encrypt 申请 ${domain} 正式证书" "
        rc=0;
        ${acme_bin} --issue -d ${domain} --standalone --keylength ec-256 || rc=\$?;
        [ \$rc -eq 0 ] || [ \$rc -eq 2 ]
    " || {
        ui_err "证书申请失败！请确认域名已解析到本机 IP 且未开启 CF 小黄云（申请时需灰云）。"
        return 1
    }

    ensure_nexus_user
    mkdir -p "$cert_dir"
    run_step "安装证书并配置自动续期重载" "
        ${acme_bin} --install-cert -d ${domain} --ecc \
            --fullchain-file ${cert_dir}/cert.pem \
            --key-file ${cert_dir}/key.pem \
            --reloadcmd 'systemctl restart nexus-xray nexus-singbox 2>/dev/null || rc-service nexus-xray restart 2>/dev/null || true' &&
        chown -R ${NEXUS_USER}:${NEXUS_USER} ${cert_dir}
    "
}

prompt_required_domain() {
    local pub_ip="$1"
    local input_domain=""
    ui_ask "请输入自有域名 (如 node.example.com)" "" input_domain
    TLS_DOMAIN="$(validate_sni "$input_domain")" || return 1

    DOMAIN_IS_CF=0
    local rc=0
    check_domain_direct_status "$TLS_DOMAIN" "$pub_ip" || rc=$?
    if [[ $rc -eq 0 ]]; then
        ui_ok "域名探测: 直连本机 (灰云)，支持任意端口与自动申请正式证书。"
        DOMAIN_IS_CF=0
    elif [[ $rc -eq 1 ]]; then
        ui_warn "域名探测: 指向非本机 IP (疑似已开 CF 小黄云 CDN)，将自动匹配 CF HTTPS 端口。"
        DOMAIN_IS_CF=1
    else
        ui_warn "域名暂未解析出 IP，请确认已在 DNS 面板配置 A 记录。"
        DOMAIN_IS_CF=2
    fi
}

prompt_cert_for_domain() {
    local cert_dir="$1"
    local domain="$2"
    local is_cf="${3:-0}"
    local domain_cert_dir="${cert_dir}/${domain}"

    if [[ -s "${domain_cert_dir}/cert.pem" && -s "${domain_cert_dir}/key.pem" ]]; then
        ui_ok "检测到 ${domain} 已有正式证书，直接复用。"
        TLS_CERT_FILE="${domain_cert_dir}/cert.pem"
        TLS_KEY_FILE="${domain_cert_dir}/key.pem"
        TLS_INSECURE=0
        TLS_CERT_SHA256=""
        return 0
    fi

    if [[ "$is_cf" -eq 1 ]]; then
        local local_pub_ip
        local_pub_ip="$(get_public_ip)"
        mkdir -p "$domain_cert_dir"
        generate_self_signed_cert "$domain_cert_dir" "$domain" "$local_pub_ip" || {
            ui_err "生成自签证书失败。"
            return 1
        }
        ui_warn "CDN 模式：已生成回源 365 天自签证书，请将 CF SSL/TLS 设为「Full」(勿选 Strict，否则报 526)。"
        TLS_CERT_FILE="${domain_cert_dir}/cert.pem"
        TLS_KEY_FILE="${domain_cert_dir}/key.pem"
        TLS_INSECURE=0
        TLS_CERT_SHA256=""
    else
        issue_acme_cert "$domain_cert_dir" "$domain" || return 1
        TLS_CERT_FILE="${domain_cert_dir}/cert.pem"
        TLS_KEY_FILE="${domain_cert_dir}/key.pem"
        TLS_INSECURE=0
        TLS_CERT_SHA256=""
    fi
}

prepare_self_signed_tls() {
    local cert_dir="$1"
    local sni="${2:-}"
    local pub_ip="${3:-}"

    if [[ -z "$sni" ]]; then
        prompt_camouflage_sni sni 0
    fi
    TLS_DOMAIN="$(validate_sni "$sni")" || return 1

    generate_self_signed_cert "$cert_dir" "$TLS_DOMAIN" "$pub_ip" || {
        ui_err "生成 365 天 ECC 自签证书失败。"
        return 1
    }
    TLS_CERT_FILE="${cert_dir}/cert.pem"
    TLS_KEY_FILE="${cert_dir}/key.pem"
    TLS_INSECURE=1
    TLS_CERT_SHA256="$(openssl x509 -in "$TLS_CERT_FILE" -noout -fingerprint -sha256 2>/dev/null | awk -F= '{print $2}' | tr -d ':\r\n' | tr 'A-F' 'a-f')"
    ui_ok "已生成 365 天 ECC 合规证书 (${TLS_DOMAIN})"
}

# Configure Hysteria 2 UDP Port Hopping (nftables / iptables)
setup_hy2_port_hopping() {
    local listen_port="$1"
    local hop_range="${2:-30000:40000}"
    local hop_start="${hop_range%:*}"
    local hop_end="${hop_range#*:}"

    local cmd=""
    if command -v nft >/dev/null 2>&1; then
        cmd="nft add table inet nexus_hop 2>/dev/null || true; \
             nft flush table inet nexus_hop 2>/dev/null || true; \
             nft add chain inet nexus_hop prerouting '{ type nat hook prerouting priority dstnat; policy accept; }'; \
             nft add rule inet nexus_hop prerouting udp dport ${hop_start}-${hop_end} redirect to :${listen_port}"
    elif command -v iptables >/dev/null 2>&1; then
        cmd="iptables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports ${listen_port} 2>/dev/null || true; \
             iptables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports ${listen_port}; \
             ip6tables -t nat -D PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports ${listen_port} 2>/dev/null || true; \
             ip6tables -t nat -A PREROUTING -p udp --dport ${hop_start}:${hop_end} -j REDIRECT --to-ports ${listen_port} 2>/dev/null || true"
    else
        ui_warn "未检测到 nftables/iptables，跳过 UDP 端口跳跃规则。"
        return 0
    fi

    run_step "配置 Hysteria 2 UDP 端口跳跃 (${hop_start}-${hop_end} -> ${listen_port})" "$cmd" || ui_warn "端口跳跃规则下发失败（可能受限容器环境），主端口仍可正常使用。"
}
