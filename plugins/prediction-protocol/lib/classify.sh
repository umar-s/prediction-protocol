#!/usr/bin/env bash
# classify.sh — the one-way command classifier. Sourced by hooks/predict-gate.sh
# and bin/predict; never executed on its own.
#
#   pp_prefilter "<command string>"     rc 0 = may contain a one-way verb (run the full classifier)
#                                       rc 1 = cannot be one-way (no vocabulary token at all)
#   pp_classify "<command string>"      rc 0 = one-way, prints "<class>\t<segment>"
#                                       rc 1 = nothing one-way
#                                       rc 2 = internal error (the caller fails closed)
#   PP_ALSO (env, newline-separated)    project wrappers declared by `predict on --also`;
#                                       matched per segment after prefix stripping, as class project:<prefix>
#
# The object is a SHELL COMMAND STRING as the Bash tool receives it — not a
# migration file (that is ci-gate/migration-guard's object) and not prose.
# Method: drop trailing comments and heredoc BODIES (the `<<` line itself stays,
# so `psql <<SQL` is still opaque input); lift `$(…)`/backtick bodies out as
# extra segments while the outer command keeps a @SUBST@ placeholder; split on
# newline, ';', '&&', '||', '|', a single '&', braces and parentheses, and the
# compound keywords then/do/else/elif; strip run-as / env / timing prefixes;
# dequote tokens; unwrap `bash -c '…'`, `sh -c`, `su -c`, `eval`; strip each
# tool's global options that precede its verb; then decide by the verb and its
# arguments. Stdin-fed shells and interpreters, remote shells and unparseable
# wrappers are opaque executors — one-way by construction. Calls to the
# plugin's own `predict` CLI are never classified (the receipt writer is not an
# action; its --action text would otherwise classify itself).
#
# Known limits (named, not parsed): `bash file.sh`, `make <target>`,
# `npm run <script>`, `python script.py`, `perl -e`, `awk system()` carry no
# verb to classify — the consuming project lists such wrappers through
# `predict on --also`, the SKILL calls wrapping-to-dodge-the-gate a bypass, and
# a `$VAR` in verb position is not expanded. Quoted text with `;`/`&&` inside
# (a commit message) splits into extra segments — more to classify, never fewer.
export LC_ALL=C

PP_VOCAB='(^|[^A-Za-z0-9_./-])(git|gh|glab|rm|find|psql|mysql|mariadb|sqlite3|mongosh|mongo|clickhouse-client|cockroach|sqlcmd|pgcli|mycli|usql|redis-cli|valkey-cli|kubectl|oc|helm|terraform|tofu|terragrunt|pulumi|ansible|ansible-playbook|docker|docker-compose|podman|nerdctl|systemctl|service|rc-service|initctl|pm2|supervisorctl|nginx|apachectl|httpd|reboot|shutdown|halt|poweroff|telinit|init|iptables|ip6tables|nft|ufw|firewall-cmd|crontab|userdel|groupdel|usermod|passwd|chpasswd|deluser|delgroup|ssh|mosh|et|scp|rsync|sftp|curl|wget|http|https|httpie|xh|hurl|aws|gcloud|az|doctl|hcloud|linode-cli|flyctl|fly|heroku|railway|vercel|netlify|wrangler|firebase|vault|gpg|op|bw|chown|chgrp|chmod|npm|yarn|pnpm|bunx|npx|twine|gem|cargo|mvn|gradle|gradlew|composer|crane|skopeo|oras|sendmail|swaks|msmtp|mutt|mailx|mail|shred|wipe|srm|wipefs|mkfs|mkfs\.[a-z0-9]+|mkswap|fdisk|sfdisk|parted|sgdisk|cfdisk|zpool|lvremove|vgremove|pvremove|dd|alembic|rails|rake|bundle|artisan|php|prisma|knex|sequelize|sequelize-cli|typeorm|flyway|liquibase|manage\.py|django-admin|python|python3|dotnet|goose|migrate|sqitch|dbmate|atlas|diesel|mix|drizzle-kit|bash|sh|zsh|dash|ksh|eval|su|perl|ruby|node|xargs|prediction-protocol/sessions)([^A-Za-z0-9_-]|$)'
# pure bash on purpose: the gate's outer wrapper calls this before anything else and must depend on nothing that can be missing
pp_prefilter() {
  local c="$1" pfx; c="${c//\\/}"; c="${c//\"\"/}"; c="${c//\'\'/}"
  [[ "$c" == *prediction-protocol/sessions/* ]] && return 0
  if [ -n "${PP_ALSO:-}" ]; then while IFS= read -r pfx; do [ -n "$pfx" ] && [[ "$c" == *"$pfx"* ]] && return 0; done <<< "$PP_ALSO"; fi
  [[ "$c" =~ $PP_VOCAB ]]
}
# for the gate's outer wrapper, which has no parser: any declared wrapper of any session on this machine
pp_prefilter_also() {
  local root="${PP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/prediction-protocol}" f pfx
  for f in "$root"/sessions/*/also; do
    [ -s "$f" ] || continue
    while IFS= read -r pfx; do [ -n "$pfx" ] && [[ "$1" == *"$pfx"* ]] && return 0; done < "$f"
  done
  return 1
}

# ---- helpers ---------------------------------------------------------------
_pp_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
# shell-dequote one token: surrounding quotes, empty ""/'' inside, backslash before a letter
_pp_dequote() {
  local w="$1"
  w="${w//\"\"/}"; w="${w//\'\'/}"
  case "$w" in \'*\') w="${w#\'}"; w="${w%\'}" ;; \"*\") w="${w#\"}"; w="${w%\"}" ;; esac
  printf '%s' "$w" | sed -E 's/\\([A-Za-z0-9_./-])/\1/g'
}

# Remove leading prefixes that do not change what the command does.
_pp_strip_prefixes() {
  local seg="$1" prev="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    prev="$seg"
    seg="$(_pp_trim "$seg")"
    seg="${seg#"("}"; seg="${seg#"{"}"; seg="$(_pp_trim "$seg")"
    case "$seg" in
      then\ *|do\ *|else\ *|elif\ *) seg="${seg#* }" ;;
      !\ *) seg="${seg#"!"}" ;;
      sudo\ *|doas\ *)
        seg="${seg#sudo }"; seg="${seg#doas }"; seg="$(_pp_trim "$seg")"
        while [[ "$seg" =~ ^-(u|g|C|p|U|D|h|T|r|t)[[:space:]]+[^[:space:]]+[[:space:]]+ ]] || [[ "$seg" =~ ^-[A-Za-z]+[[:space:]]+ ]] || [[ "$seg" =~ ^--[a-z-]+(=[^[:space:]]*)?[[:space:]]+ ]] || [[ "$seg" =~ ^--[[:space:]]+ ]]; do
          seg="${seg#"${BASH_REMATCH[0]}"}"
        done ;;
      env\ *)
        seg="${seg#env }"; seg="$(_pp_trim "$seg")"
        while [[ "$seg" =~ ^(-[A-Za-z]+|--[a-z-]+(=[^[:space:]]*)?|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)[[:space:]]+ ]]; do seg="${seg#"${BASH_REMATCH[0]}"}"; done ;;
      time\ *|nohup\ *|exec\ *|builtin\ *|chronic\ *|unbuffer\ *|caffeinate\ *|setsid\ *)
        seg="${seg#* }"; seg="$(_pp_trim "$seg")"
        while [[ "$seg" =~ ^-[A-Za-z]+[[:space:]]+ ]]; do seg="${seg#"${BASH_REMATCH[0]}"}"; done ;;
      command\ *)
        seg="${seg#command }"; seg="$(_pp_trim "$seg")"
        while [[ "$seg" =~ ^-[pvV]+[[:space:]]+ ]]; do seg="${seg#"${BASH_REMATCH[0]}"}"; done ;;
      stdbuf\ *) seg="${seg#stdbuf }"; seg="$(_pp_trim "$seg")"
        while [[ "$seg" =~ ^(-[ioe][^[:space:]]*|--(input|output|error)=[^[:space:]]*)[[:space:]]+ ]]; do seg="${seg#"${BASH_REMATCH[0]}"}"; done ;;
      nice\ *|ionice\ *|watch\ *) seg="${seg#* }"; seg="$(_pp_trim "$seg")"
        while [[ "$seg" =~ ^(-[nct][[:space:]]*-?[0-9.]+|--[a-z-]+(=[^[:space:]]*)?|-[A-Za-z]+)[[:space:]]+ ]]; do seg="${seg#"${BASH_REMATCH[0]}"}"; done ;;
      timeout\ *)
        seg="${seg#timeout }"; seg="$(_pp_trim "$seg")"
        while [[ "$seg" =~ ^(-[A-Za-z]+([[:space:]]+[^[:space:]-][^[:space:]]*)?|--[a-z-]+(=[^[:space:]]*)?)[[:space:]]+ ]]; do seg="${seg#"${BASH_REMATCH[0]}"}"; done
        [[ "$seg" =~ ^[0-9.]+[smhd]?[[:space:]]+ ]] && seg="${seg#"${BASH_REMATCH[0]}"}" ;;
      flock\ *)
        seg="${seg#flock }"; seg="$(_pp_trim "$seg")"
        while [[ "$seg" =~ ^(-[A-Za-z]+([[:space:]]+[0-9]+)?|--[a-z-]+(=[^[:space:]]*)?)[[:space:]]+ ]]; do seg="${seg#"${BASH_REMATCH[0]}"}"; done
        seg="${seg#* }"; seg="$(_pp_trim "$seg")"           # the lock file / fd
        case "$seg" in -c\ *|--command\ *) seg="bash $seg" ;; esac ;;
      xargs\ *|parallel\ *)
        seg="${seg#* }"; seg="$(_pp_trim "$seg")"
        while [[ "$seg" =~ ^(-[0a-zA-Z]+([[:space:]]+[^[:space:]-][^[:space:]]*)?|-I[[:space:]]*[^[:space:]]+|--[a-z-]+(=[^[:space:]]*)?|:::)[[:space:]]+ ]]; do seg="${seg#"${BASH_REMATCH[0]}"}"; done ;;
      chroot\ *) seg="${seg#chroot }"; seg="$(_pp_trim "$seg")"; seg="${seg#* }" ;;
      *) if [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*=([^[:space:]\'\"]*|\'[^\']*\'|\"[^\"]*\")[[:space:]]+ ]]; then seg="${seg#"${BASH_REMATCH[0]}"}"; fi ;;
    esac
    [ "$seg" = "$prev" ] && break
  done
  printf '%s' "$seg"
}

# Extract the quoted program after `bash -c` / `sh -c` / `su … -c` / `eval`.
_pp_unwrap() {
  local seg="$1" rest
  if [[ "$seg" =~ ^(bash|sh|zsh|dash|ksh)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c[A-Za-z]*[[:space:]]+(.*)$ ]]; then rest="${BASH_REMATCH[3]}"
  elif [[ "$seg" =~ ^su([[:space:]]+-l?|[[:space:]]+[A-Za-z0-9_-]+)*[[:space:]]+(-c|--command(=|[[:space:]]+))(.*)$ ]]; then rest="${BASH_REMATCH[4]}"
  elif [[ "$seg" =~ ^eval[[:space:]]+(.*)$ ]]; then rest="${BASH_REMATCH[1]}"
  else return 1; fi
  rest="$(_pp_trim "$rest")"
  case "$rest" in
    \'*\'*) rest="${rest#\'}"; rest="${rest%%\'*}" ;;
    \"*\"*) rest="${rest#\"}"; rest="${rest%\"*}" ;;
    \'*|\"*) return 1 ;;
    *) ;;
  esac
  [ -n "$rest" ] || return 1
  case "$rest" in \$*) return 1 ;; esac                      # "$CMD" — cannot see the program
  printf '%s' "$rest"
}

# every non-flag argument is a path inside scratch space; at least one path seen
_pp_all_paths_tmp() {
  local w n=0
  for w in "$@"; do
    case "$w" in -*) continue ;; esac
    n=$((n+1))
    case "$w" in *..*) return 1 ;; esac
    case "$w" in
      /tmp/*|/var/tmp/*|'$TMPDIR'*|'${TMPDIR'*|'"$TMPDIR'*|'"${TMPDIR'*|/tmp|'$TMPDIR'|\'/tmp/*|\"/tmp/*) continue ;;
      *) return 1 ;;
    esac
  done
  [ "$n" -gt 0 ]
}
_pp_has_local_url() { local w; for w in "$@"; do [[ "$w" =~ ^[\'\"]?(https?://)?(localhost|127\.[0-9.]+|0\.0\.0\.0|\[::1\]|::1|host\.docker\.internal)([:/]|[\'\"]?$) ]] && return 0; done; return 1; }
_pp_has_dry_run() { [[ "$1" =~ (^|[[:space:]])(--dry-run(=[a-z]+)?|--check|--syntax-check|-n|--dry|--plan)([[:space:]]|$) ]]; }

# SQL text: rc 0 when any statement is not a pure read
_pp_sql_is_write() {
  local sql st
  sql="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  while IFS= read -r st; do
    st="$(_pp_trim "$st")"; st="${st#\'}"; st="${st#\"}"; st="$(_pp_trim "$st")"
    [ -n "$st" ] || continue
    case "$st" in
      \\i*|\\ir*|\\copy*from*|source\ *) return 0 ;;          # meta-commands that read a file or copy in
      select\ *|show\ *|describe\ *|desc\ *|\\d*|\\l*|\\dt*|\\conninfo*|table\ *|values\ *) continue ;;
    esac
    [[ "$st" =~ (^|[^a-z_])(insert|update|delete|drop|truncate|alter|create|grant|revoke|merge|replace|rename|vacuum|reindex|cluster|refresh|call|do|copy|lock|set|reset|begin|commit|rollback|flush|flushall|flushdb|dropdatabase|deletemany|deleteone|drop\(|remove\(|insertone|insertmany|updateone|updatemany|bulkwrite|createindex|dropindex|findoneandupdate|findoneanddelete|findoneandreplace|renamecollection)([^a-z_]|$) ]] && return 0
  done <<< "$(printf '%s' "$sql" | tr ';' '\n')"
  return 1
}

# strip a tool's global options that precede its verb
_pp_strip_global_opts() {   # tool rest → prints rest'
  local t="$1" r="$2"
  case "$t" in
    git) while [[ "$r" =~ ^(-C[[:space:]]*[^[:space:]]+|-c[[:space:]]*[^[:space:]]+|--git-dir(=|[[:space:]]+)[^[:space:]]+|--work-tree(=|[[:space:]]+)[^[:space:]]+|--namespace(=|[[:space:]]+)[^[:space:]]+|--exec-path(=[^[:space:]]*)?|--config-env=[^[:space:]]+|--no-pager|-P|-p|--bare|--no-optional-locks|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-replace-objects)[[:space:]]+ ]]; do r="${r#"${BASH_REMATCH[0]}"}"; done ;;
    kubectl|oc|helm) while [[ "$r" =~ ^(-n[[:space:]]*[^[:space:]]+|--namespace(=|[[:space:]]+)[^[:space:]]+|--context(=|[[:space:]]+)[^[:space:]]+|--kubeconfig(=|[[:space:]]+)[^[:space:]]+|--kube-context(=|[[:space:]]+)[^[:space:]]+|-s[[:space:]]*[^[:space:]]+|--server(=|[[:space:]]+)[^[:space:]]+|--token(=|[[:space:]]+)[^[:space:]]+|--user(=|[[:space:]]+)[^[:space:]]+|--cluster(=|[[:space:]]+)[^[:space:]]+|--insecure-skip-tls-verify|--request-timeout(=|[[:space:]]+)[^[:space:]]+|-v[[:space:]]*[0-9]+|--v=[0-9]+|--debug)[[:space:]]+ ]]; do r="${r#"${BASH_REMATCH[0]}"}"; done ;;
    docker|podman|nerdctl) while [[ "$r" =~ ^(-H[[:space:]]*[^[:space:]]+|--host(=|[[:space:]]+)[^[:space:]]+|--context(=|[[:space:]]+)[^[:space:]]+|-c[[:space:]]*[^[:space:]]+|--config(=|[[:space:]]+)[^[:space:]]+|-l[[:space:]]*[^[:space:]]+|--log-level(=|[[:space:]]+)[^[:space:]]+|-D|--debug|--tls[a-z]*|--tlscacert(=|[[:space:]]+)[^[:space:]]+|--tlscert(=|[[:space:]]+)[^[:space:]]+|--tlskey(=|[[:space:]]+)[^[:space:]]+)[[:space:]]+ ]]; do r="${r#"${BASH_REMATCH[0]}"}"; done ;;
    aws) while [[ "$r" =~ ^(--profile(=|[[:space:]]+)[^[:space:]]+|--region(=|[[:space:]]+)[^[:space:]]+|--output(=|[[:space:]]+)[^[:space:]]+|--endpoint-url(=|[[:space:]]+)[^[:space:]]+|--no-cli-pager|--no-paginate|--debug|--no-verify-ssl|--cli-read-timeout(=|[[:space:]]+)[0-9]+|--cli-connect-timeout(=|[[:space:]]+)[0-9]+|--color(=|[[:space:]]+)[a-z]+|--query(=|[[:space:]]+)[^[:space:]]+)[[:space:]]+ ]]; do r="${r#"${BASH_REMATCH[0]}"}"; done ;;
    gcloud|az) while [[ "$r" =~ ^(--project(=|[[:space:]]+)[^[:space:]]+|--account(=|[[:space:]]+)[^[:space:]]+|--configuration(=|[[:space:]]+)[^[:space:]]+|--subscription(=|[[:space:]]+)[^[:space:]]+|--verbosity(=|[[:space:]]+)[^[:space:]]+|--quiet|-q|--format(=|[[:space:]]+)[^[:space:]]+|-o[[:space:]]*[^[:space:]]+|--output(=|[[:space:]]+)[^[:space:]]+)[[:space:]]+ ]]; do r="${r#"${BASH_REMATCH[0]}"}"; done ;;
    npm|yarn|pnpm) while [[ "$r" =~ ^(--registry(=|[[:space:]]+)[^[:space:]]+|--prefix(=|[[:space:]]+)[^[:space:]]+|-C[[:space:]]*[^[:space:]]+|--cwd(=|[[:space:]]+)[^[:space:]]+|--userconfig(=|[[:space:]]+)[^[:space:]]+|--loglevel(=|[[:space:]]+)[^[:space:]]+|--silent|-s|--verbose|-d|--dd|--ddd)[[:space:]]+ ]]; do r="${r#"${BASH_REMATCH[0]}"}"; done ;;
    terraform|tofu|terragrunt) while [[ "$r" =~ ^(-chdir=[^[:space:]]+|--terragrunt-[a-z-]+(=[^[:space:]]*)?([[:space:]]+[^-][^[:space:]]*)?)[[:space:]]+ ]]; do r="${r#"${BASH_REMATCH[0]}"}"; done ;;
    gh|glab) while [[ "$r" =~ ^(-R[[:space:]]*[^[:space:]]+|--repo(=|[[:space:]]+)[^[:space:]]+|--hostname(=|[[:space:]]+)[^[:space:]]+)[[:space:]]+ ]]; do r="${r#"${BASH_REMATCH[0]}"}"; done ;;
    redis-cli|valkey-cli) while [[ "$r" =~ ^(-h[[:space:]]*[^[:space:]]+|-p[[:space:]]*[0-9]+|-a[[:space:]]*[^[:space:]]+|-n[[:space:]]*[0-9]+|-u[[:space:]]*[^[:space:]]+|--user[[:space:]]+[^[:space:]]+|--pass[[:space:]]+[^[:space:]]+|--tls|--no-auth-warning|-c|-3)[[:space:]]+ ]]; do r="${r#"${BASH_REMATCH[0]}"}"; done ;;
  esac
  printf '%s' "$r"
}

# ---- one segment -------------------------------------------------------------
_pp_segment() {
  local raw="$1" piped=0 seg depth="${2:-0}" inner
  seg="$(_pp_trim "$raw")"
  [ -n "$seg" ] || return 1
  if [[ "$seg" == @PIPE@* ]]; then piped=1; seg="$(_pp_trim "${seg#@PIPE@}")"; fi
  seg="$(_pp_strip_prefixes "$seg")"
  [ -n "$seg" ] || return 1

  # state tampering: writing into the plugin's own session state
  if [[ "$seg" == */prediction-protocol/sessions/* ]] && { [[ "$seg" =~ (^|[[:space:]])(rm|mv|cp|tee|sed|touch|mkdir|chmod|ln|truncate|dd|python3?|perl|ruby|node|cat|echo|printf)([[:space:]]|$) ]] || [[ "$seg" == *\>* ]]; }; then printf 'state-tamper'; return 0; fi

  # the plugin's own CLI is never an action
  [[ "$seg" =~ ^(\"?\$\{?PREDICT\}?\"?|\"?\$\{?P\}?\"?|[^[:space:]]*/bin/predict|predict)[[:space:]]+(on|off|open|close|ack|retry|withdraw|report|status|lint|classify|selftest|version|help)([[:space:]]|$) ]] && return 1

  # project wrappers (predict on --also)
  if [ -n "${PP_ALSO:-}" ]; then
    local pfx; while IFS= read -r pfx; do [ -n "$pfx" ] || continue
      case "$seg" in "$pfx"|"$pfx "*) printf 'project:%s' "$pfx"; return 0 ;; esac
    done <<< "$PP_ALSO"
  fi

  # wrappers: recurse into the quoted program, or treat as opaque
  if [[ "$seg" =~ ^(bash|sh|zsh|dash|ksh)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c[A-Za-z]*([[:space:]]|$) ]] || [[ "$seg" =~ ^eval([[:space:]]|$) ]] || [[ "$seg" =~ ^su([[:space:]]+-l?|[[:space:]]+[A-Za-z0-9_-]+)*[[:space:]]+(-c|--command) ]]; then
    if [ "$depth" -ge 3 ]; then printf 'opaque-exec'; return 0; fi
    if inner="$(_pp_unwrap "$seg")"; then
      local r; r="$(pp_classify "$inner" "$((depth+1))")" && { printf '%s' "${r%%	*}"; return 0; }
      return 1
    fi
    printf 'opaque-exec'; return 0
  fi

  local -a w0; read -r -a w0 <<< "$seg"
  local -a w=(); local x; for x in "${w0[@]}"; do w+=("$(_pp_dequote "$x")"); done
  local v="${w[0]}" vbase rest
  vbase="${v##*/}"
  rest="$(_pp_trim "${seg#"${w0[0]}"}")"
  # rebuild rest from dequoted words for matching (sqlarg is taken from raw below)
  local drest=""; local i; for ((i=1;i<${#w[@]};i++)); do drest="$drest${w[$i]} "; done; drest="$(_pp_trim "$drest")"
  drest="$(_pp_strip_global_opts "$vbase" "$drest")"
  local -a a=(); read -r -a a <<< "$drest"
  rest="$drest"

  # stdin-fed shells and interpreters are opaque executors
  case "$vbase" in
    bash|sh|zsh|dash|ksh|python|python3|perl|ruby|node)
      local _hs='[[:space:]]<<<' _ri='[[:space:]]<[[:space:]]*[^<&]' _hd0='[[:space:]]<<[^<]'
      { [ "$piped" = 1 ] || [[ "$raw" =~ $_hs ]] || [[ "$raw" =~ $_ri ]] || [[ "$raw" =~ $_hd0 ]] || [[ "$rest" =~ (^|[[:space:]])(-|-s)([[:space:]]|$) ]]; } && { printf 'opaque-exec'; return 0; } ;;
  esac

  # help / version — only as the first argument after the verb (or after one subcommand), never for remote shells
  case "$vbase" in ssh|mosh|et) ;; *)
    [[ "${a[0]:-}" =~ ^(--help|-h|--version|-V|help|version)$ ]] && return 1
    [[ "${a[1]:-}" =~ ^(--help|-h|help)$ ]] && [ "${#a[@]}" -le 3 ] && [[ "$rest" != *exec* ]] && return 1
    [[ "${a[2]:-}" =~ ^(--help|-h)$ ]] && [ "${#a[@]}" -le 3 ] && [[ "$rest" != *exec* ]] && return 1 ;;
  esac

  case "$vbase" in
    # ---- migration runners -------------------------------------------------
    alembic) [[ "$rest" =~ (^|[[:space:]])(upgrade|downgrade|stamp)([[:space:]]|$) ]] && { printf 'migrate'; return 0; } ;;
    rails|rake|bundle) [[ "$seg" =~ (^|[[:space:]])db:(migrate|rollback|drop|reset|schema:load|structure:load|seed|setup|create)([:[:space:]]|$) ]] && { printf 'migrate'; return 0; } ;;
    artisan|php) [[ "$seg" =~ artisan[[:space:]]+(migrate|db:seed|db:wipe|migrate:[a-z]+) ]] && { printf 'migrate'; return 0; } ;;
    prisma|npx|yarn|pnpm|bunx)
      [[ "$seg" =~ prisma[[:space:]]+(migrate[[:space:]]+(deploy|reset|resolve|dev)|db[[:space:]]+(push|execute)) ]] && { printf 'migrate'; return 0; }
      [[ "$seg" =~ knex[[:space:]]+migrate:(latest|rollback|up|down) ]] && { printf 'migrate'; return 0; }
      [[ "$seg" =~ sequelize(-cli)?[[:space:]]+db:(migrate|seed|drop|create) ]] && { printf 'migrate'; return 0; }
      [[ "$seg" =~ typeorm[[:space:]]+migration:(run|revert) ]] && { printf 'migrate'; return 0; }
      [[ "$seg" =~ drizzle-kit[[:space:]]+(push|migrate|drop) ]] && { printf 'migrate'; return 0; }
      if [[ "$vbase" != npx ]] && [[ "$rest" =~ ^(publish|unpublish|deprecate)([[:space:]]|$) ]]; then _pp_has_dry_run "$rest" && return 1; printf 'publish'; return 0; fi ;;
    knex) [[ "$rest" =~ ^migrate:(latest|rollback|up|down) ]] && { printf 'migrate'; return 0; } ;;
    sequelize|sequelize-cli) [[ "$rest" =~ ^db:(migrate|seed|drop|create) ]] && { printf 'migrate'; return 0; } ;;
    typeorm) [[ "$rest" =~ ^migration:(run|revert) ]] && { printf 'migrate'; return 0; } ;;
    flyway) [[ "$rest" =~ (^|[[:space:]])(migrate|clean|undo|repair|baseline)([[:space:]]|$) ]] && { printf 'migrate'; return 0; } ;;
    liquibase) [[ "$rest" =~ (^|[[:space:]])(update|rollback|drop-all|changelog-sync)[a-zA-Z-]*([[:space:]]|$) ]] && { printf 'migrate'; return 0; } ;;
    manage.py|django-admin) [[ "$rest" =~ (^|[[:space:]])(migrate|flush|sqlflush|loaddata)([[:space:]]|$) ]] && { printf 'migrate'; return 0; } ;;
    python|python3) [[ "$seg" =~ manage\.py[[:space:]]+(migrate|flush|loaddata)([[:space:]]|$) ]] && { printf 'migrate'; return 0; } ;;
    dotnet) [[ "$rest" =~ ^ef[[:space:]]+database[[:space:]]+(update|drop) ]] && { printf 'migrate'; return 0; }
            [[ "$rest" =~ ^nuget[[:space:]]+push ]] && { printf 'publish'; return 0; } ;;
    goose) [[ "$rest" =~ (^|[[:space:]])(up|down|redo|reset|up-to|down-to)([[:space:]]|$) ]] && { printf 'migrate'; return 0; } ;;
    migrate) [[ "$rest" =~ (^|[[:space:]])(up|down|drop|force|goto)([[:space:]]|$) ]] && { printf 'migrate'; return 0; } ;;
    sqitch) [[ "$rest" =~ ^(deploy|revert|rebase) ]] && { printf 'migrate'; return 0; } ;;
    dbmate) [[ "$rest" =~ ^(up|down|rollback|drop|migrate) ]] && { printf 'migrate'; return 0; } ;;
    atlas) [[ "$rest" =~ ^(migrate|schema)[[:space:]]+apply ]] && { printf 'migrate'; return 0; } ;;
    diesel) [[ "$rest" =~ ^migration[[:space:]]+(run|revert|redo) ]] && { printf 'migrate'; return 0; } ;;
    mix) [[ "$rest" =~ ^ecto\.(migrate|rollback|drop|reset) ]] && { printf 'migrate'; return 0; } ;;

    # ---- SQL / KV clients -------------------------------------------------
    psql|mysql|mariadb|sqlite3|mongosh|mongo|clickhouse-client|cockroach|sqlcmd|pgcli|mycli|usql)
      local _hd='<<' _rd='[[:space:]]<[[:space:]]*[^<&]'
      [ "$piped" = 1 ] && { printf 'sql-opaque-input'; return 0; }
      [[ "$rest" =~ (^|[[:space:]])(-[A-Za-z]*[fi][A-Za-z]*|--file|--file=|--input-file)([[:space:]=]|$) ]] && [[ "$vbase" != mongosh && "$vbase" != mongo ]] && { printf 'sql-opaque-input'; return 0; }
      [[ "$raw" =~ $_hd ]] && { printf 'sql-opaque-input'; return 0; }
      [[ "$raw" =~ $_rd ]] && { printf 'sql-opaque-input'; return 0; }
      [[ "$vbase" =~ ^(mongosh|mongo)$ ]] && [[ "$rest" =~ (^|[[:space:]])[^[:space:]]+\.js([[:space:]]|$) ]] && { printf 'sql-opaque-input'; return 0; }
      local sqlarg=""
      # -c/-e/-Q and their clustered forms (-tAc, -Nse, -qc); long forms; sqlite3/usql positional SQL
      if [[ "$raw" =~ (^|[[:space:]])(-[A-Za-z0-9]*[ceQ]|--command|--execute|--eval|--query)(=|[[:space:]]+)(.*)$ ]]; then sqlarg="${BASH_REMATCH[4]}"
      elif [[ "$vbase" = sqlite3 ]] && [[ "$raw" =~ sqlite3[[:space:]]+(-[A-Za-z]+[[:space:]]+)*[^[:space:]]+[[:space:]]+(.+)$ ]]; then sqlarg="${BASH_REMATCH[2]}"
      elif [[ "$vbase" = usql ]] && [[ "$raw" =~ usql[[:space:]]+[^[:space:]]+[[:space:]]+(.+)$ ]]; then sqlarg="${BASH_REMATCH[1]}"; fi
      [ -n "$sqlarg" ] && _pp_sql_is_write "$sqlarg" && { printf 'sql-write'; return 0; }
      return 1 ;;
    redis-cli|valkey-cli)
      local _rd2='[[:space:]]<[[:space:]]*[^<&]'
      { [ "$piped" = 1 ] || [[ "$raw" =~ $_rd2 ]] || [[ "$rest" =~ (^|[[:space:]])(-x|--pipe)([[:space:]]|$) ]]; } && { printf 'sql-opaque-input'; return 0; }
      local lrest; lrest="$(printf '%s' "$rest" | tr 'A-Z' 'a-z')"
      [[ "$lrest" =~ (^|[[:space:]])(flushall|flushdb|del|unlink|config[[:space:]]+(set|rewrite|resetstat)|shutdown|debug|restore|rename|renamenx|set|setex|setnx|psetex|mset|msetnx|getset|getdel|append|incr|incrby|incrbyfloat|decr|decrby|hset|hsetnx|hmset|hdel|hincrby|lpush|rpush|lpushx|rpushx|lpop|rpop|lrem|ltrim|lset|sadd|srem|spop|smove|zadd|zrem|zincrby|zremrangebyscore|zremrangebyrank|expire|pexpire|expireat|persist|migrate|replicaof|slaveof|eval|evalsha|script[[:space:]]+(flush|load)|client[[:space:]]+kill|acl[[:space:]]+(setuser|deluser)|save|bgsave|bgrewriteaof|cluster[[:space:]]+(reset|failover|forget|meet)|xadd|xdel|xtrim|publish|copy|move|swapdb)([[:space:]]|$) ]] && { printf 'kv-write'; return 0; }
      return 1 ;;

    # ---- VCS: history rewrite, merges, releases -----------------------------
    git)
      if [[ "$rest" =~ ^push([[:space:]]|$) ]]; then
        _pp_has_dry_run "$rest" && return 1
        [[ "$rest" =~ (^|[[:space:]])(-[a-zA-Z]*f[a-zA-Z]*|--force|--force-with-lease(=[^[:space:]]*)?|--force-if-includes|-[a-zA-Z]*d[a-zA-Z]*|--delete|--prune|--mirror)([[:space:]]|$) ]] && { printf 'vcs-force'; return 0; }
        [[ "$rest" =~ [[:space:]]\+[^[:space:]] ]] && { printf 'vcs-force'; return 0; }
        [[ "$rest" =~ [[:space:]]:[A-Za-z0-9_./-]+([[:space:]]|$) ]] && { printf 'vcs-force'; return 0; }
        [[ "$rest" =~ (^|[[:space:]])\$[A-Za-z_{] ]] && { printf 'vcs-force'; return 0; }   # an unexpanded flag variable
        return 1
      fi
      [[ "$rest" =~ ^branch[[:space:]]+(.*[[:space:]])?(-D|--delete[[:space:]]+--force|--force[[:space:]]+--delete|-[a-zA-Z]*[dD][a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*[dD])([[:space:]]|$) ]] && { printf 'vcs-force'; return 0; }
      [[ "$rest" =~ ^(filter-branch|filter-repo|replace)([[:space:]]|$) ]] && { printf 'vcs-force'; return 0; }
      [[ "$rest" =~ ^update-ref[[:space:]]+-d ]] && { printf 'vcs-force'; return 0; }
      [[ "$rest" =~ ^reflog[[:space:]]+(expire|delete) ]] && { printf 'vcs-force'; return 0; }
      [[ "$rest" =~ ^gc[[:space:]].*--prune ]] && { printf 'vcs-force'; return 0; }
      return 1 ;;
    gh)
      [[ "$rest" =~ ^pr[[:space:]]+merge([[:space:]]|$) ]] && { printf 'vcs-merge'; return 0; }
      [[ "$rest" =~ ^release[[:space:]]+(create|delete|edit|upload|delete-asset)([[:space:]]|$) ]] && { printf 'release'; return 0; }
      [[ "$rest" =~ ^repo[[:space:]]+(delete|archive|rename|transfer|unarchive)([[:space:]]|$) ]] && { printf 'vcs-force'; return 0; }
      [[ "$rest" =~ ^secret[[:space:]]+(set|delete|remove)([[:space:]]|$) ]] && { printf 'secrets'; return 0; }
      [[ "$rest" =~ ^variable[[:space:]]+(set|delete)([[:space:]]|$) ]] && { printf 'secrets'; return 0; }
      [[ "$rest" =~ ^workflow[[:space:]]+(run|enable|disable)([[:space:]]|$) ]] && { printf 'infra'; return 0; }
      if [[ "$rest" =~ ^api([[:space:]]|$) ]]; then
        [[ "$rest" =~ (-X|--method)[[:space:]=]*(GET|get)([[:space:]]|$) ]] && return 1
        [[ "$rest" =~ (^|[[:space:]])graphql([[:space:]]|$) ]] && return 1
        [[ "$rest" =~ (-X|--method)[[:space:]=]*(POST|PUT|DELETE|PATCH) ]] && { printf 'http-write'; return 0; }
        [[ "$rest" =~ (^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]=]|$) ]] && { printf 'http-write'; return 0; }
      fi
      return 1 ;;
    glab)
      [[ "$rest" =~ ^mr[[:space:]]+merge([[:space:]]|$) ]] && { printf 'vcs-merge'; return 0; }
      [[ "$rest" =~ ^release[[:space:]]+(create|delete|upload)([[:space:]]|$) ]] && { printf 'release'; return 0; }
      [[ "$rest" =~ ^(repo[[:space:]]+delete|variable[[:space:]]+(set|delete|update)) ]] && { printf 'secrets'; return 0; }
      return 1 ;;

    # ---- infrastructure ------------------------------------------------------
    kubectl|oc)
      _pp_has_dry_run "$rest" && return 1
      [[ "$rest" =~ (^|[[:space:]])diff([[:space:]]|$) ]] && return 1
      [[ "$rest" =~ ^rollout[[:space:]]+(status|history)([[:space:]]|$) ]] && return 1
      [[ "$rest" =~ ^exec([[:space:]]|$) ]] && { printf 'remote-exec'; return 0; }
      [[ "$rest" =~ ^(delete|apply|create|replace|patch|rollout|scale|drain|cordon|uncordon|taint|edit|set|expose|run|annotate|label|cp|attach|debug)([[:space:]]|$) ]] && { printf 'infra'; return 0; }
      return 1 ;;
    helm) _pp_has_dry_run "$rest" && return 1; [[ "$rest" =~ ^(install|upgrade|uninstall|delete|rollback|push)([[:space:]]|$) ]] && { printf 'infra'; return 0; } ;;
    terraform|tofu|terragrunt)
      [[ "$rest" =~ (^|[[:space:]])(apply|destroy|import|taint|untaint|force-unlock|run-all[[:space:]]+(apply|destroy))([[:space:]]|$) ]] && { printf 'infra'; return 0; }
      [[ "$rest" =~ ^state[[:space:]]+(rm|mv|push|replace-provider)([[:space:]]|$) ]] && { printf 'infra'; return 0; }
      [[ "$rest" =~ ^workspace[[:space:]]+delete([[:space:]]|$) ]] && { printf 'infra'; return 0; } ;;
    pulumi) [[ "$rest" =~ ^(up|destroy|refresh|import|state[[:space:]]+delete)([[:space:]]|$) ]] && { printf 'infra'; return 0; } ;;
    ansible-playbook) _pp_has_dry_run "$rest" && return 1; [[ "$rest" =~ (^|[[:space:]])--list-(tasks|hosts|tags)([[:space:]]|$) ]] && return 1; printf 'infra'; return 0 ;;
    ansible) _pp_has_dry_run "$rest" && return 1; [[ "$rest" =~ (^|[[:space:]])-m[[:space:]]+(shell|command|raw|file|copy|service|systemd|apt|yum|dnf|user|lineinfile|template)([[:space:]]|$) ]] && { printf 'infra'; return 0; } ;;
    docker|podman|nerdctl)
      [[ "$rest" =~ ^exec([[:space:]]|$) ]] && { printf 'remote-exec'; return 0; }
      [[ "$rest" =~ ^compose[[:space:]]+(.*[[:space:]])?exec([[:space:]]|$) ]] && { printf 'remote-exec'; return 0; }
      [[ "$rest" =~ ^(rm|rmi|kill|stop|restart|push|system[[:space:]]+prune|volume[[:space:]]+(rm|prune)|network[[:space:]]+(rm|prune)|container[[:space:]]+(rm|prune|kill|stop|restart)|image[[:space:]]+(rm|prune)|stack[[:space:]]+rm|service[[:space:]]+(rm|update|scale)|builder[[:space:]]+prune)([[:space:]]|$) ]] && { printf 'infra'; return 0; }
      [[ "$rest" =~ ^(compose|stack)[[:space:]]+(.*[[:space:]])?(down|rm|kill|restart|stop)([[:space:]]|$) ]] && { printf 'infra'; return 0; }
      return 1 ;;
    docker-compose) [[ "$rest" =~ (^|[[:space:]])exec([[:space:]]|$) ]] && { printf 'remote-exec'; return 0; }; [[ "$rest" =~ (^|[[:space:]])(down|rm|kill|restart|stop)([[:space:]]|$) ]] && { printf 'infra'; return 0; } ;;
    systemctl|service|rc-service|initctl)
      [[ "$rest" =~ (^|[[:space:]])(restart|stop|disable|mask|kill|reload-or-restart|try-restart|isolate|poweroff|reboot|halt)([[:space:]]|$) ]] && { printf 'service'; return 0; } ;;
    pm2) [[ "$rest" =~ ^(restart|stop|delete|kill|reload|flush|resurrect)([[:space:]]|$) ]] && { printf 'service'; return 0; } ;;
    supervisorctl) [[ "$rest" =~ ^(restart|stop|remove|shutdown|signal)([[:space:]]|$) ]] && { printf 'service'; return 0; } ;;
    nginx|apachectl|httpd) [[ "$rest" =~ (^|[[:space:]])(-s[[:space:]]+(stop|quit|reload)|stop|restart|graceful-stop)([[:space:]]|$) ]] && { printf 'service'; return 0; } ;;
    reboot|shutdown|halt|poweroff|telinit) printf 'service'; return 0 ;;
    init) [[ "$rest" =~ ^[0-6]$ ]] && { printf 'service'; return 0; } ;;
    iptables|ip6tables|nft|ufw|firewall-cmd)
      [[ "$rest" =~ (^|[[:space:]])(-F|-X|-D|-A|-I|-P|flush|delete|add|insert|disable|enable|reset|--remove[a-z-]*|--add[a-z-]*)([[:space:]]|$) ]] && { printf 'infra'; return 0; } ;;
    crontab) [[ "$rest" =~ (^|[[:space:]])-r([[:space:]]|$) ]] && { printf 'infra'; return 0; }
             [[ "$rest" =~ (^|[[:space:]])-[lei]([[:space:]]|$) ]] && return 1
             [ "$piped" = 1 ] && { printf 'infra'; return 0; }; [[ "${a[0]:-}" != "" && "${a[0]:-}" != -* ]] && { printf 'infra'; return 0; } ;;
    userdel|groupdel|usermod|passwd|chpasswd|deluser|delgroup) printf 'secrets'; return 0 ;;

    # ---- remote execution (opaque executors) ----------------------------------
    ssh|mosh|et)
      [[ "$rest" =~ (^|[[:space:]])-[NLRDW]([[:space:]]|$) ]] && return 1
      local -a nonflag=(); local skip=0
      for x in "${a[@]}"; do
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$x" in -o|-p|-i|-l|-F|-J|-b|-c|-e|-m|-E|-I|-Q|-S|-B) skip=1 ;; -*) ;; *) nonflag+=("$x") ;; esac
      done
      [ "${#nonflag[@]}" -ge 2 ] && { printf 'remote-exec'; return 0; }
      return 1 ;;
    scp|rsync|sftp)
      _pp_has_dry_run "$rest" && return 1
      [[ "$vbase" = rsync ]] && [[ "$rest" =~ (^|[[:space:]])-[a-zA-Z]*n[a-zA-Z]*([[:space:]]|$) ]] && return 1
      [[ "${a[-1]:-}" == *:* ]] && [[ "${a[-1]:-}" != *://* ]] && { printf 'remote-write'; return 0; }
      [[ "$rest" =~ (^|[[:space:]])--delete ]] && [[ "$rest" == *:* ]] && { printf 'remote-write'; return 0; }
      return 1 ;;

    # ---- HTTP with a side effect, not on localhost ---------------------------
    curl|wget|http|https|httpie|xh|hurl)
      local mut=0
      [[ "$rest" =~ (^|[[:space:]])(-[A-Za-z]*X|--request|--method)[[:space:]=]*[\'\"]?(POST|PUT|DELETE|PATCH|post|put|delete|patch) ]] && mut=1
      [[ "$rest" =~ (^|[[:space:]])(-[A-Za-z]*[dFT]|--data|--data-raw|--data-binary|--data-urlencode|--data-ascii|--json|--form|--form-string|--upload-file|--post-data|--post-file)([[:space:]=@]|$) ]] && mut=1
      [[ "$rest" =~ (^|[[:space:]])--method=(POST|PUT|DELETE|PATCH|post|put|delete|patch) ]] && mut=1
      [[ "$vbase" =~ ^(http|https|httpie|xh)$ ]] && [[ "$rest" =~ (^|[[:space:]])(POST|PUT|DELETE|PATCH)([[:space:]]|$) ]] && mut=1
      [ "$mut" = 1 ] || return 1
      _pp_has_local_url "${a[@]}" && return 1
      printf 'http-write'; return 0 ;;

    # ---- cloud, grants, secrets -----------------------------------------------
    aws)
      if [[ "$rest" =~ ^(s3|s3api)[[:space:]]+(cp|mv|sync)([[:space:]]|$) ]]; then [[ "${a[-1]:-}" == s3://* ]] && { printf 'cloud-write'; return 0; }; return 1; fi
      [[ "$rest" =~ ^(s3|s3api)[[:space:]]+(rm|rb|delete-object|delete-objects|delete-bucket|put-object|put-bucket-[a-z-]+|delete-bucket-[a-z-]+|put-[a-z-]+)([[:space:]]|$) ]] && { printf 'cloud-write'; return 0; }
      [[ "$rest" =~ ^[a-z0-9-]+[[:space:]]+(describe|get|list|lookup|start-query|get-query-results|filter-log-events|batch-get|head-|wait|help)[a-z-]*([[:space:]]|$) ]] && return 1
      [[ "$rest" =~ ^(configure|sts|eks[[:space:]]+update-kubeconfig|ecr[[:space:]]+get-login)([[:space:]]|$) ]] && return 1
      [[ "$rest" =~ ^[a-z0-9-]+[[:space:]]+(delete|terminate|put|update|modify|rotate|revoke|attach|detach|reboot|stop|start|deregister|disable|enable|create|remove|restore|run|invoke|tag|untag|set|cancel|associate|disassociate|register|release|reset|import|send|publish|copy|batch-(delete|put|write))[a-z-]*([[:space:]]|$) ]] && { printf 'cloud-write'; return 0; }
      return 1 ;;
    gcloud|az|doctl|hcloud|linode-cli|flyctl|fly|heroku|railway|vercel|netlify|wrangler|firebase)
      [[ "$rest" =~ (^|[[:space:]])(list|describe|get|show|logs|status|info|ls|tail|whoami|version|config[[:space:]]+(set|get|list)|account[[:space:]]+(set|show|list)|auth[[:space:]]+(login|list|print-access-token)|components|init)([[:space:]]|$) ]] && return 1
      [[ "$rest" =~ (^|[[:space:]])(delete|create|update|deploy|rollback|remove|restart|stop|start|reset|set|add|rm|destroy|scale|resize|promote|publish|push|run|exec|ssh|kill|purge)([[:space:]]|$) ]] && { printf 'cloud-write'; return 0; }
      [[ "$rest" =~ (^|[[:space:]])(secrets?|config:set|env[[:space:]]+(add|rm|pull))([[:space:]]|$) ]] && { printf 'secrets'; return 0; }
      [[ "$vbase" =~ ^(vercel|netlify|fly|flyctl|railway|wrangler|firebase)$ ]] && [[ "$rest" =~ (^|[[:space:]])(--prod|--production)([[:space:]]|$) ]] && { printf 'cloud-write'; return 0; }
      [[ "$vbase" = vercel ]] && [ "${#a[@]}" -eq 0 ] && { printf 'cloud-write'; return 0; }
      return 1 ;;
    vault)
      [[ "$rest" =~ (^|[[:space:]])(delete|revoke|rotate|write|put|destroy|undelete|disable|enable|tune|policy[[:space:]]+(write|delete)|token[[:space:]]+(create|revoke)|lease[[:space:]]+revoke|kv[[:space:]]+(put|delete|destroy|metadata[[:space:]]+delete))([[:space:]]|$) ]] && { printf 'secrets'; return 0; } ;;
    gpg) [[ "$rest" =~ (--delete-secret-keys|--delete-keys|--delete-secret-and-public-keys) ]] && { printf 'secrets'; return 0; } ;;
    op|bw) [[ "$rest" =~ (^|[[:space:]])(item[[:space:]]+(delete|edit|create)|delete|edit|create)([[:space:]]|$) ]] && { printf 'secrets'; return 0; } ;;
    chown|chgrp|chmod)
      [[ "$rest" =~ (^|[[:space:]])-[a-zA-Z]*R ]] && ! _pp_all_paths_tmp "${a[@]}" && [[ "$rest" =~ [[:space:]]/(etc|usr|var|bin|sbin|lib|lib64|boot|opt|srv|root|home|mnt)([[:space:]/]|$) ]] && { printf 'files'; return 0; }
      return 1 ;;

    # ---- publishing ----------------------------------------------------------
    npm) _pp_has_dry_run "$rest" && return 1; [[ "$rest" =~ ^(publish|unpublish|deprecate|dist-tag[[:space:]]+(add|rm)|owner[[:space:]]+(add|rm)|token[[:space:]]+(create|revoke))([[:space:]]|$) ]] && { printf 'publish'; return 0; } ;;
    twine) [[ "$rest" =~ ^upload ]] && { printf 'publish'; return 0; } ;;
    gem) [[ "$rest" =~ ^(push|yank|owner) ]] && { printf 'publish'; return 0; } ;;
    cargo) _pp_has_dry_run "$rest" && return 1; [[ "$rest" =~ ^(publish|yank|owner) ]] && { printf 'publish'; return 0; } ;;
    mvn) [[ "$rest" =~ (^|[[:space:]])deploy([[:space:]]|$) ]] && { printf 'publish'; return 0; } ;;
    gradle|gradlew) [[ "$rest" =~ (^|[[:space:]])publish[A-Za-z]*([[:space:]]|$) ]] && { printf 'publish'; return 0; } ;;
    composer) [[ "$rest" =~ ^publish ]] && { printf 'publish'; return 0; } ;;
    crane|skopeo|oras) [[ "$rest" =~ ^(push|copy|delete|tag) ]] && { printf 'publish'; return 0; } ;;

    # ---- mail / messaging ----------------------------------------------------
    sendmail|swaks|msmtp|mutt|mailx) printf 'mail'; return 0 ;;
    mail) [[ "$rest" =~ (^|[[:space:]])-s([[:space:]]|$) ]] && { printf 'mail'; return 0; } ;;

    # ---- files and block devices ----------------------------------------------
    rm)
      [[ "$rest" =~ (^|[[:space:]])(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)([[:space:]]|$) ]] || return 1
      [ "$piped" = 1 ] && { printf 'files'; return 0; }
      [[ "$rest" == *@SUBST@* ]] && { printf 'files'; return 0; }
      _pp_all_paths_tmp "${a[@]}" && return 1
      printf 'files'; return 0 ;;
    find)
      [[ "$rest" =~ (^|[[:space:]])(-delete|-exec[[:space:]]+rm|-execdir[[:space:]]+rm|-ok[[:space:]]+rm)([[:space:]]|$) ]] || return 1
      local -a fp=(); for x in "${a[@]}"; do [[ "$x" == -* ]] && break; fp+=("$x"); done
      [ "${#fp[@]}" -gt 0 ] && _pp_all_paths_tmp "${fp[@]}" && return 1
      printf 'files'; return 0 ;;
    shred|wipe|srm|wipefs|mkfs|mkfs.*|mkswap|lvremove|vgremove|pvremove) printf 'files'; return 0 ;;
    fdisk|sfdisk|parted|sgdisk|cfdisk)
      [[ "$rest" =~ (^|[[:space:]])(-l|-p|--list|print|-s|-d|-i|--dump|unit|--version)([[:space:]]|$) ]] && ! [[ "$rest" =~ (^|[[:space:]])(-w|mklabel|mkpart|rm|--delete|-n|-N|-Z|-z|-g|-o)([[:space:]]|$) ]] && return 1
      printf 'files'; return 0 ;;
    zpool|zfs)
      [[ "$rest" =~ ^(destroy|remove|detach|offline|clear|replace|labelclear|create|add|rollback|rename|set)([[:space:]]|$) ]] && { printf 'files'; return 0; } ;;
    dd) [[ "$rest" =~ of=/dev/(null|stdout|stderr|zero)([[:space:]]|$) ]] && return 1; [[ "$rest" =~ of=/dev/ ]] && { printf 'files'; return 0; } ;;
  esac
  return 1
}

# ---- entry point -----------------------------------------------------------
# lift $(…) and `…` bodies out: the outer keeps @SUBST@, bodies become extra lines
_pp_lift_substitutions() {
  local s="$1" out="" bodies="" i n depth=0 c body="" inbt=0
  n=${#s}
  for ((i=0;i<n;i++)); do
    c="${s:$i:1}"
    if [ "$depth" -gt 0 ]; then
      if [ "$c" = "(" ]; then depth=$((depth+1)); body="$body$c"
      elif [ "$c" = ")" ]; then depth=$((depth-1)); if [ "$depth" -eq 0 ]; then bodies="$bodies"$'\n'"$body"; body=""; out="$out@SUBST@"; else body="$body$c"; fi
      else body="$body$c"; fi
      continue
    fi
    if [ "$inbt" = 1 ]; then
      if [ "$c" = '`' ]; then inbt=0; bodies="$bodies"$'\n'"$body"; body=""; out="$out@SUBST@"; else body="$body$c"; fi
      continue
    fi
    if [ "$c" = '$' ] && [ "${s:$((i+1)):1}" = "(" ]; then depth=1; i=$((i+1)); continue; fi
    if [ "$c" = '`' ]; then inbt=1; continue; fi
    out="$out$c"
  done
  [ "$depth" -gt 0 ] || [ "$inbt" = 1 ] && { bodies="$bodies"$'\n'"$body"; out="$out@SUBST@"; }
  printf '%s%s' "$out" "$bodies"
}
# quote-aware split into segments: separators count only outside quotes
_pp_split() {
  local s="$1" n i c q="" out="" p="" esc=0 nx
  n=${#s}
  for ((i=0;i<n;i++)); do
    c="${s:$i:1}"; nx="${s:$((i+1)):1}"
    if [ "$esc" = 1 ]; then out="$out$c"; esc=0; p="$c"; continue; fi
    if [ -n "$q" ]; then
      if [ "$c" = "$q" ]; then q=""; elif [ "$q" = '"' ] && [ "$c" = '\' ]; then esc=1; fi
      out="$out$c"; p="$c"; continue
    fi
    case "$c" in
      '\') esc=1; out="$out$c" ;;
      "'"|'"') q="$c"; out="$out$c" ;;
      '|') if [ "$nx" = '|' ]; then i=$((i+1)); out="$out"$'\n'; elif [ "$nx" = '&' ]; then i=$((i+1)); out="$out"$'\n'"@PIPE@ "; else out="$out"$'\n'"@PIPE@ "; fi ;;
      '&') if [ "$nx" = '&' ]; then i=$((i+1)); out="$out"$'\n'; elif [ "$p" = '>' ] || [ "$p" = '<' ] || [ "$nx" = '>' ]; then out="$out$c"; else out="$out"$'\n'; fi ;;
      ';'|$'\n') out="$out"$'\n' ;;
      '('|')'|'{'|'}') out="$out " ;;
      *) out="$out$c" ;;
    esac
    p="$c"
  done
  printf '%s\n' "$out"
}
# drop heredoc bodies: keep the `<<TAG` line, skip lines until the terminator
_pp_drop_heredocs() {
  awk '
    BEGIN { tag="" }
    tag != "" { if ($0 == tag || $0 ~ ("^[\t]*" tag "$")) { tag="" } ; next }
    { line=$0
      if (match(line, /<<-?[ \t]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?/)) {
        t=substr(line, RSTART, RLENGTH); sub(/^<<-?[ \t]*/, "", t); gsub(/['"'"'"]/, "", t); tag=t }
      print line }'
}
pp_classify() {
  local cmd="$1" depth="${2:-0}" split seg cls n=0
  [ -n "$cmd" ] || return 1
  [ "$depth" -gt 0 ] || pp_prefilter "$cmd" || return 1
  # a patch fed to `apply_patch` through the shell (Codex's editor as a command) names its targets in
  # `*** … File:` headers inside the heredoc body that is dropped below — a header on the protocol state is state-tamper
  if [[ "$cmd" == *apply_patch* ]] && printf '%s\n' "$cmd" | grep -Eq '^\*\*\* (Add File|Update File|Delete File|Move to): .*prediction-protocol/sessions/'; then printf 'state-tamper\tapply_patch header on the protocol state\n'; return 0; fi
  cmd="$(printf '%s\n' "$cmd" | tr -d '\r' | _pp_drop_heredocs | sed -E 's/(^|[[:space:]])#[^\x27"]*$//')" || return 2
  cmd="$(_pp_lift_substitutions "$cmd")"
  split="$(_pp_split "$cmd")" || return 2
  while IFS= read -r seg; do
    n=$((n+1)); [ "$n" -le 400 ] || { printf 'unclassifiable\t%s\n' "too many segments"; return 0; }
    cls="$(_pp_segment "$seg" "$depth")" && { printf '%s\t%s\n' "$cls" "$(_pp_trim "${seg#@PIPE@}")"; return 0; }
  done <<< "$split"
  return 1
}
