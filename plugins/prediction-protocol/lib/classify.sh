#!/usr/bin/env bash
# classify.sh — the one-way command classifier. Sourced by hooks/predict-gate.sh
# and bin/predict; never executed on its own.
#
#   pp_classify "<command string>"      rc 0 = one-way, prints "<class>\t<segment>"
#                                       rc 1 = nothing one-way
#                                       rc 2 = internal error (the caller fails closed)
#
# The object is a SHELL COMMAND STRING as the Bash tool receives it — not a
# migration file (that is ci-gate/migration-guard's object) and not prose.
# Method: split into segments on newline, ';', '&&', '||', '|', '$(' and
# backticks (a '|' or ';' inside quotes splits too — that yields MORE segments
# to classify, never fewer); strip run-as / env / timing prefixes; unwrap
# `bash -c '…'`, `sh -c`, `eval`; then decide by the verb at position 0 and
# its arguments. Known limits (named, not parsed): `bash file.sh`, `make
# <target>`, `npm run <script>` carry no verb to classify — the consuming
# project lists such wrappers through `predict on --also`, and the SKILL calls
# wrapping-to-dodge-the-gate a bypass. Locale must not decide verdicts.
export LC_ALL=C

# ---- helpers ---------------------------------------------------------------
_pp_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# Remove leading prefixes that do not change what the command does:
# sudo [-flags [arg]], env [-flags] [VAR=val…], VAR=val…, time, nohup, nice [-n N],
# timeout [--opts] N, command, exec, builtin, xargs [-flags], doas, chroot <dir>.
_pp_strip_prefixes() {
  local seg="$1" prev=""
  local i
  for i in 1 2 3 4 5 6 7 8; do
    prev="$seg"
    seg="$(_pp_trim "$seg")"
    # leading ( { ) } and "@PIPE@" marker are kept out of the verb position
    seg="${seg#"("}"; seg="${seg#"{"}"; seg="$(_pp_trim "$seg")"
    case "$seg" in
      sudo\ *|doas\ *)
        seg="${seg#sudo }"; seg="${seg#doas }"; seg="$(_pp_trim "$seg")"
        # sudo flags: -u user, -g group, -E, -n, -S, -H, -i, -s, --preserve-env=…, --
        while [[ "$seg" =~ ^-(u|g|C|p|U|D|h)[[:space:]]+[^[:space:]]+[[:space:]]+ ]] || [[ "$seg" =~ ^-[A-Za-z]+[[:space:]]+ ]] || [[ "$seg" =~ ^--[a-z-]+(=[^[:space:]]*)?[[:space:]]+ ]]; do
          seg="${seg#"${BASH_REMATCH[0]}"}"
        done ;;
      env\ *)
        seg="${seg#env }"; seg="$(_pp_trim "$seg")"
        while [[ "$seg" =~ ^(-[A-Za-z]+|--[a-z-]+(=[^[:space:]]*)?|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)[[:space:]]+ ]]; do seg="${seg#"${BASH_REMATCH[0]}"}"; done ;;
      time\ *|nohup\ *|command\ *|exec\ *|builtin\ *)
        seg="${seg#* }" ;;
      nice\ *)
        seg="${seg#nice }"; seg="$(_pp_trim "$seg")"
        [[ "$seg" =~ ^-n[[:space:]]*-?[0-9]+[[:space:]]+ ]] && seg="${seg#"${BASH_REMATCH[0]}"}" ;;
      timeout\ *)
        seg="${seg#timeout }"; seg="$(_pp_trim "$seg")"
        while [[ "$seg" =~ ^(-[A-Za-z]+([[:space:]]+[^[:space:]-][^[:space:]]*)?|--[a-z-]+(=[^[:space:]]*)?)[[:space:]]+ ]]; do seg="${seg#"${BASH_REMATCH[0]}"}"; done
        [[ "$seg" =~ ^[0-9]+[smhd]?[[:space:]]+ ]] && seg="${seg#"${BASH_REMATCH[0]}"}" ;;
      xargs\ *)
        seg="${seg#xargs }"; seg="$(_pp_trim "$seg")"
        while [[ "$seg" =~ ^(-[0a-zA-Z]+([[:space:]]+[^[:space:]-][^[:space:]]*)?|-I[[:space:]]*[^[:space:]]+|--[a-z-]+(=[^[:space:]]*)?)[[:space:]]+ ]]; do seg="${seg#"${BASH_REMATCH[0]}"}"; done ;;
      chroot\ *)
        seg="${seg#chroot }"; seg="$(_pp_trim "$seg")"; seg="${seg#* }" ;;
      *)
        # VAR=val prefix
        if [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*=([^[:space:]\'\"]*|\'[^\']*\'|\"[^\"]*\")[[:space:]]+ ]]; then seg="${seg#"${BASH_REMATCH[0]}"}"; fi ;;
    esac
    [ "$seg" = "$prev" ] && break
  done
  printf '%s' "$seg"
}

# Extract the quoted argument after `bash -c` / `sh -c` / `eval`. Prints it, or
# nothing (rc 1) when it cannot be isolated — the caller then treats the
# segment as opaque-exec (one-way).
_pp_unwrap() {
  local seg="$1" rest
  if [[ "$seg" =~ ^(bash|sh|zsh|dash|ksh)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c[A-Za-z]*[[:space:]]+(.*)$ ]]; then rest="${BASH_REMATCH[3]}"
  elif [[ "$seg" =~ ^eval[[:space:]]+(.*)$ ]]; then rest="${BASH_REMATCH[1]}"
  else return 1; fi
  rest="$(_pp_trim "$rest")"
  case "$rest" in
    \'*\'*) rest="${rest#\'}"; rest="${rest%%\'*}" ;;
    \"*\"*) rest="${rest#\"}"; rest="${rest%\"*}" ;;
    \'*|\"*) return 1 ;;               # unterminated quote — cannot isolate
    *) ;;                               # bare word(s): take as is
  esac
  [ -n "$rest" ] || return 1
  printf '%s' "$rest"
}

# Every non-flag argument of rm/find-like segments points into scratch space?
_pp_all_paths_tmp() {
  local w
  for w in "$@"; do
    case "$w" in
      -*) continue ;;
      /tmp/*|/var/tmp/*|'$TMPDIR'*|'${TMPDIR'*|'"$TMPDIR'*|'"${TMPDIR'*|/tmp|'$TMPDIR'|\'/tmp/*|\"/tmp/*) continue ;;
      *) return 1 ;;
    esac
  done
  return 0
}

_pp_has_local_url() {
  local w
  for w in "$@"; do
    [[ "$w" =~ ^[\'\"]?(https?://)?(localhost|127\.[0-9.]+|0\.0\.0\.0|\[::1\]|::1|host\.docker\.internal)([:/]|[\'\"]?$) ]] && return 0
  done
  return 1
}
_pp_has_url() { local w; for w in "$@"; do [[ "$w" =~ ^[\'\"]?https?:// ]] && return 0; [[ "$w" =~ ^[\'\"]?[A-Za-z0-9.-]+\.[a-z]{2,}(:[0-9]+)?(/|[\'\"]?$) ]] && return 0; done; return 1; }

# SQL text: rc 0 when it is not a pure read.
_pp_sql_is_write() {
  local sql; sql="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"; sql="$(_pp_trim "$sql")"
  sql="${sql#\'}"; sql="${sql#\"}"; sql="$(_pp_trim "$sql")"
  case "$sql" in
    select\ *|show\ *|explain\ *|describe\ *|desc\ *|with\ *|\\d*|\\l*|\\dt*|\\conninfo*|table\ *|values\ *) return 1 ;;
  esac
  [[ "$sql" =~ (^|[^a-z_])(insert|update|delete|drop|truncate|alter|create|grant|revoke|merge|replace|rename|vacuum|reindex|cluster|refresh|call|do|copy|lock|set|reset|begin|commit|rollback|flushall|flushdb|dropdatabase|deletemany|deleteone|drop\(|remove\(|insertone|insertmany|updateone|updatemany|bulkwrite)([^a-z_]|$) ]] && return 0
  return 1
}

# ---- one segment -------------------------------------------------------------
# prints "<class>" and returns 0 when one-way; returns 1 otherwise.
_pp_segment() {
  local raw="$1" piped=0 seg depth="${2:-0}" inner
  seg="$(_pp_trim "$raw")"
  [ -n "$seg" ] || return 1
  if [[ "$seg" == @PIPE@* ]]; then piped=1; seg="$(_pp_trim "${seg#@PIPE@}")"; fi
  seg="$(_pp_strip_prefixes "$seg")"
  [ -n "$seg" ] || return 1

  # wrappers: recurse into the quoted program, or treat as opaque
  if [[ "$seg" =~ ^(bash|sh|zsh|dash|ksh)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c[A-Za-z]*([[:space:]]|$) ]] || [[ "$seg" =~ ^eval([[:space:]]|$) ]]; then
    if [ "$depth" -ge 3 ]; then printf 'opaque-exec'; return 0; fi
    if inner="$(_pp_unwrap "$seg")"; then
      local r; r="$(pp_classify "$inner" "$((depth+1))")" && { printf '%s' "${r%%	*}"; return 0; }
      return 1
    fi
    printf 'opaque-exec'; return 0
  fi

  # help/version requests do nothing — judged on the unquoted text only, so
  # `ssh prod 'systemctl restart app --help'` stays remote-exec
  local unq; unq="$(printf '%s' "$seg" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")"
  [[ "$unq" =~ (^|[[:space:]])(--help|-h|--version|-V|help|version)([[:space:]]|$) ]] && return 1
  local -a w; read -r -a w <<< "$seg"
  local v="${w[0]}" rest="${seg#"${w[0]}"}"; rest="$(_pp_trim "$rest")"
  local vbase="${v##*/}"

  case "$vbase" in
    # ---- migration runners -------------------------------------------------
    alembic) [[ "$rest" =~ (^|[[:space:]])(upgrade|downgrade|stamp)([[:space:]]|$) ]] && { printf 'migrate'; return 0; } ;;
    rails|rake|bin/rails|bundle)
      [[ "$seg" =~ (^|[[:space:]])db:(migrate|rollback|drop|reset|schema:load|structure:load|seed|setup|create)([:[:space:]]|$) ]] && { printf 'migrate'; return 0; } ;;
    artisan|php)
      [[ "$seg" =~ artisan[[:space:]]+(migrate|db:seed|db:wipe|migrate:[a-z]+) ]] && { printf 'migrate'; return 0; } ;;
    prisma|npx|yarn|pnpm|bunx)
      [[ "$seg" =~ prisma[[:space:]]+(migrate[[:space:]]+(deploy|reset|resolve|dev)|db[[:space:]]+(push|execute)) ]] && { printf 'migrate'; return 0; }
      [[ "$seg" =~ knex[[:space:]]+migrate:(latest|rollback|up|down) ]] && { printf 'migrate'; return 0; }
      [[ "$seg" =~ sequelize(-cli)?[[:space:]]+db:(migrate|seed|drop|create) ]] && { printf 'migrate'; return 0; }
      [[ "$seg" =~ typeorm[[:space:]]+migration:(run|revert) ]] && { printf 'migrate'; return 0; }
      [[ "$seg" =~ drizzle-kit[[:space:]]+(push|migrate|drop) ]] && { printf 'migrate'; return 0; }
      [[ "$seg" =~ (^|[[:space:]])(publish|unpublish|deprecate)([[:space:]]|$) ]] && [[ "$vbase" != npx ]] && { printf 'publish'; return 0; } ;;
    knex) [[ "$rest" =~ ^migrate:(latest|rollback|up|down) ]] && { printf 'migrate'; return 0; } ;;
    sequelize|sequelize-cli) [[ "$rest" =~ ^db:(migrate|seed|drop|create) ]] && { printf 'migrate'; return 0; } ;;
    typeorm) [[ "$rest" =~ ^migration:(run|revert) ]] && { printf 'migrate'; return 0; } ;;
    flyway) [[ "$rest" =~ (^|[[:space:]])(migrate|clean|undo|repair|baseline)([[:space:]]|$) ]] && { printf 'migrate'; return 0; } ;;
    liquibase) [[ "$rest" =~ (^|[[:space:]])(update|rollback|drop-all|changelog-sync)[a-zA-Z-]*([[:space:]]|$) ]] && { printf 'migrate'; return 0; } ;;
    manage.py|django-admin) [[ "$rest" =~ (^|[[:space:]])(migrate|flush|sqlflush|loaddata)([[:space:]]|$) ]] && { printf 'migrate'; return 0; } ;;
    python|python3)
      [[ "$seg" =~ manage\.py[[:space:]]+(migrate|flush|loaddata)([[:space:]]|$) ]] && { printf 'migrate'; return 0; } ;;
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
      [ "$piped" = 1 ] && { printf 'sql-opaque-input'; return 0; }
      [[ "$seg" =~ (^|[[:space:]])(-f|--file|--file=|-i|--input-file)([[:space:]=]|$) ]] && { printf 'sql-opaque-input'; return 0; }
      local _hd='<<' _rd='[[:space:]]<[[:space:]]*[^<]'
      [[ "$raw" =~ $_hd ]] && { printf 'sql-opaque-input'; return 0; }
      [[ "$raw" =~ $_rd ]] && { printf 'sql-opaque-input'; return 0; }
      local sqlarg=""
      if [[ "$seg" =~ (^|[[:space:]])(-c|-e|--command|--execute|--eval|--query|-q)(=|[[:space:]]+)(.*)$ ]]; then sqlarg="${BASH_REMATCH[4]}"; fi
      [ -n "$sqlarg" ] && _pp_sql_is_write "$sqlarg" && { printf 'sql-write'; return 0; }
      return 1 ;;
    redis-cli|valkey-cli)
      [[ "$rest" =~ (^|[[:space:]])(-n[[:space:]]+[0-9]+[[:space:]]+)?(flushall|flushdb|del|unlink|config[[:space:]]+set|shutdown|debug|restore|rename|set|hset|lpush|rpush|sadd|zadd|expire|persist|migrate|replicaof|slaveof)([[:space:]]|$) ]] && { printf 'kv-write'; return 0; }
      [[ "$rest" =~ (^|[[:space:]])(FLUSHALL|FLUSHDB|DEL|UNLINK|CONFIG[[:space:]]+SET|SHUTDOWN|RESTORE|RENAME|SET|HSET|LPUSH|RPUSH|SADD|ZADD|EXPIRE|MIGRATE|REPLICAOF|SLAVEOF)([[:space:]]|$) ]] && { printf 'kv-write'; return 0; }
      [ "$piped" = 1 ] && { printf 'sql-opaque-input'; return 0; }
      return 1 ;;

    # ---- VCS: history rewrite, merges, releases -----------------------------
    git)
      if [[ "$rest" =~ ^push([[:space:]]|$) ]]; then
        [[ "$rest" =~ (^|[[:space:]])(-f|--force|--force-with-lease(=[^[:space:]]*)?|--force-if-includes|-d|--delete|--prune|--mirror)([[:space:]]|$) ]] && { printf 'vcs-force'; return 0; }
        [[ "$rest" =~ [[:space:]]\+[^[:space:]] ]] && { printf 'vcs-force'; return 0; }
        [[ "$rest" =~ [[:space:]]:[A-Za-z0-9_./-]+([[:space:]]|$) ]] && { printf 'vcs-force'; return 0; }
        return 1
      fi
      [[ "$rest" =~ ^branch[[:space:]]+(.*[[:space:]])?(-D|--delete[[:space:]]+--force|--force[[:space:]]+--delete|-[a-zA-Z]*[dD][a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*[dD])([[:space:]]|$) ]] && { printf 'vcs-force'; return 0; }
      [[ "$rest" =~ ^(filter-branch|filter-repo|replace)([[:space:]]|$) ]] && { printf 'vcs-force'; return 0; }
      [[ "$rest" =~ ^update-ref[[:space:]]+-d ]] && { printf 'vcs-force'; return 0; }
      return 1 ;;
    gh)
      [[ "$rest" =~ ^pr[[:space:]]+merge([[:space:]]|$) ]] && { printf 'vcs-merge'; return 0; }
      [[ "$rest" =~ ^release[[:space:]]+(create|delete|edit|upload|delete-asset)([[:space:]]|$) ]] && { printf 'release'; return 0; }
      [[ "$rest" =~ ^repo[[:space:]]+(delete|archive|rename|transfer|unarchive)([[:space:]]|$) ]] && { printf 'vcs-force'; return 0; }
      [[ "$rest" =~ ^secret[[:space:]]+(set|delete|remove)([[:space:]]|$) ]] && { printf 'secrets'; return 0; }
      [[ "$rest" =~ ^variable[[:space:]]+(set|delete)([[:space:]]|$) ]] && { printf 'secrets'; return 0; }
      [[ "$rest" =~ ^api[[:space:]].*(-X|--method)[[:space:]=]*(POST|PUT|DELETE|PATCH) ]] && { printf 'http-write'; return 0; }
      [[ "$rest" =~ ^api[[:space:]].*(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]=]|$) ]] && { printf 'http-write'; return 0; }
      return 1 ;;
    glab)
      [[ "$rest" =~ ^mr[[:space:]]+merge([[:space:]]|$) ]] && { printf 'vcs-merge'; return 0; }
      [[ "$rest" =~ ^release[[:space:]]+(create|delete|upload)([[:space:]]|$) ]] && { printf 'release'; return 0; }
      [[ "$rest" =~ ^(repo[[:space:]]+delete|variable[[:space:]]+(set|delete|update)) ]] && { printf 'secrets'; return 0; }
      return 1 ;;

    # ---- infrastructure ------------------------------------------------------
    kubectl|oc)
      [[ "$rest" =~ (^|[[:space:]])(--dry-run|diff)([[:space:]=]|$) ]] && return 1
      [[ "$rest" =~ ^(delete|apply|create|replace|patch|rollout|scale|drain|cordon|uncordon|taint|exec|edit|set|expose|run|annotate|label|cp|attach|debug)([[:space:]]|$) ]] && { [[ "$rest" =~ ^exec ]] && printf 'remote-exec' || printf 'infra'; return 0; }
      [[ "$rest" =~ (^|[[:space:]])(--dry-run|diff)([[:space:]=]|$) ]] && return 1
      return 1 ;;
    helm) [[ "$rest" =~ ^(install|upgrade|uninstall|delete|rollback|push)([[:space:]]|$) ]] && { printf 'infra'; return 0; } ;;
    terraform|tofu|terragrunt)
      [[ "$rest" =~ (^|[[:space:]])(apply|destroy|import|taint|untaint|force-unlock|run-all[[:space:]]+(apply|destroy))([[:space:]]|$) ]] && { printf 'infra'; return 0; }
      [[ "$rest" =~ ^state[[:space:]]+(rm|mv|push|replace-provider)([[:space:]]|$) ]] && { printf 'infra'; return 0; }
      [[ "$rest" =~ ^workspace[[:space:]]+delete([[:space:]]|$) ]] && { printf 'infra'; return 0; } ;;
    pulumi) [[ "$rest" =~ ^(up|destroy|refresh|import|state[[:space:]]+delete)([[:space:]]|$) ]] && { printf 'infra'; return 0; } ;;
    ansible-playbook) [[ "$rest" =~ (^|[[:space:]])--check([[:space:]]|$) ]] || { printf 'infra'; return 0; } ;;
    ansible) [[ "$rest" =~ (^|[[:space:]])-m[[:space:]]+(shell|command|raw|file|copy|service|systemd|apt|yum|dnf|user)([[:space:]]|$) ]] && { printf 'infra'; return 0; } ;;
    docker|podman|nerdctl)
      [[ "$rest" =~ ^(rm|rmi|kill|stop|restart|push|exec|system[[:space:]]+prune|volume[[:space:]]+(rm|prune)|network[[:space:]]+(rm|prune)|container[[:space:]]+(rm|prune|kill|stop|restart)|image[[:space:]]+(rm|prune)|stack[[:space:]]+rm|service[[:space:]]+(rm|update|scale)|builder[[:space:]]+prune)([[:space:]]|$) ]] && { [[ "$rest" =~ ^exec ]] && printf 'remote-exec' || printf 'infra'; return 0; }
      [[ "$rest" =~ ^(compose|stack)[[:space:]]+(.*[[:space:]])?(down|rm|kill|restart|stop)([[:space:]]|$) ]] && { printf 'infra'; return 0; }
      [[ "$rest" =~ ^compose[[:space:]]+(.*[[:space:]])?exec([[:space:]]|$) ]] && { printf 'remote-exec'; return 0; }
      return 1 ;;
    docker-compose) [[ "$rest" =~ (^|[[:space:]])(down|rm|kill|restart|stop|exec)([[:space:]]|$) ]] && { printf 'infra'; return 0; } ;;
    systemctl|service|rc-service|initctl)
      [[ "$rest" =~ (^|[[:space:]])(restart|stop|disable|mask|kill|reload-or-restart|try-restart|isolate|poweroff|reboot|halt)([[:space:]]|$) ]] && { printf 'service'; return 0; } ;;
    pm2) [[ "$rest" =~ ^(restart|stop|delete|kill|reload|flush|resurrect)([[:space:]]|$) ]] && { printf 'service'; return 0; } ;;
    supervisorctl) [[ "$rest" =~ ^(restart|stop|remove|shutdown|signal)([[:space:]]|$) ]] && { printf 'service'; return 0; } ;;
    nginx|apachectl|httpd) [[ "$rest" =~ (^|[[:space:]])(-s[[:space:]]+(stop|quit|reload)|stop|restart|graceful-stop)([[:space:]]|$) ]] && { printf 'service'; return 0; } ;;
    reboot|shutdown|halt|poweroff|telinit) printf 'service'; return 0 ;;
    init) [[ "$rest" =~ ^[0-6]$ ]] && { printf 'service'; return 0; } ;;
    iptables|ip6tables|nft|ufw|firewall-cmd)
      [[ "$rest" =~ (^|[[:space:]])(-F|-X|-D|-A|-I|-P|flush|delete|add|insert|disable|reset|--remove|--add)([[:space:]]|$) ]] && { printf 'infra'; return 0; } ;;
    crontab) [[ "$rest" =~ (^|[[:space:]])-r([[:space:]]|$) ]] && { printf 'infra'; return 0; } ;;
    userdel|groupdel|usermod|passwd|chpasswd|deluser|delgroup) printf 'secrets'; return 0 ;;

    # ---- remote execution (opaque executors) ----------------------------------
    ssh|mosh|et)
      [[ "$rest" =~ (^|[[:space:]])-[NLRDW]([[:space:]]|$) ]] && return 1
      local -a a=("${w[@]:1}") nonflag=() ; local x skip=0
      for x in "${a[@]}"; do
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$x" in -o|-p|-i|-l|-F|-J|-b|-c|-e|-m|-E|-I|-Q|-S|-B) skip=1 ;; -*) ;; *) nonflag+=("$x") ;; esac
      done
      [ "${#nonflag[@]}" -ge 2 ] && { printf 'remote-exec'; return 0; }
      return 1 ;;
    scp|rsync|sftp)
      [[ "$rest" =~ (^|[[:space:]])[^[:space:]/]+@?[A-Za-z0-9._-]+:[^[:space:]]*$ ]] || [[ "$rest" =~ (^|[[:space:]])[A-Za-z0-9._-]+:[^[:space:]]*[[:space:]]*$ ]] && [[ "${w[-1]}" == *:* ]] && { printf 'remote-write'; return 0; }
      return 1 ;;

    # ---- HTTP with a side effect, not on localhost ---------------------------
    curl|wget|http|https|httpie|xh|hurl)
      local mut=0
      [[ "$rest" =~ (^|[[:space:]])(-X|--request|--method)[[:space:]=]*[\'\"]?(POST|PUT|DELETE|PATCH|post|put|delete|patch) ]] && mut=1
      [[ "$rest" =~ (^|[[:space:]])(-d|--data|--data-raw|--data-binary|--data-urlencode|--data-ascii|--json|-F|--form|--form-string|-T|--upload-file|--post-data|--post-file)([[:space:]=]|$) ]] && mut=1
      [[ "$rest" =~ (^|[[:space:]])--method=(POST|PUT|DELETE|PATCH) ]] && mut=1
      [[ "$vbase" =~ ^(http|https|httpie|xh)$ ]] && [[ "$rest" =~ (^|[[:space:]])(POST|PUT|DELETE|PATCH)([[:space:]]|$) ]] && mut=1
      [ "$mut" = 1 ] || return 1
      _pp_has_local_url "${w[@]:1}" && return 1
      printf 'http-write'; return 0 ;;

    # ---- cloud, grants, secrets -----------------------------------------------
    aws)
      [[ "$rest" =~ ^(s3|s3api)[[:space:]]+(rm|rb|sync|mv|cp|delete-object|delete-bucket|put-object|put-bucket-[a-z-]+|delete-bucket-[a-z-]+)([[:space:]]|$) ]] && { printf 'cloud-write'; return 0; }
      [[ "$rest" =~ ^[a-z0-9-]+[[:space:]]+(delete|terminate|put|update|modify|rotate|revoke|attach|detach|reboot|stop|start|deregister|disable|enable|create|remove|restore|run|invoke|tag|untag|set|cancel|associate|disassociate|register|release|reset|import|send|publish)[a-z-]*([[:space:]]|$) ]] && { printf 'cloud-write'; return 0; }
      return 1 ;;
    gcloud|az|doctl|hcloud|linode-cli|flyctl|fly|heroku|railway|vercel|netlify|wrangler|firebase)
      [[ "$rest" =~ (^|[[:space:]])(delete|create|update|deploy|rollback|remove|restart|stop|start|reset|set|add|rm|destroy|scale|resize|promote|publish|push|run|exec|ssh|kill)([[:space:]]|$) ]] && { printf 'cloud-write'; return 0; }
      [[ "$rest" =~ (^|[[:space:]])(secrets?|config:set|config[[:space:]]+set|env[[:space:]]+(add|rm|pull))([[:space:]]|$) ]] && { printf 'secrets'; return 0; }
      return 1 ;;
    vault)
      [[ "$rest" =~ (^|[[:space:]])(delete|revoke|rotate|write|put|destroy|undelete|disable|enable|tune|policy[[:space:]]+(write|delete)|token[[:space:]]+(create|revoke)|lease[[:space:]]+revoke|kv[[:space:]]+(put|delete|destroy|metadata[[:space:]]+delete))([[:space:]]|$) ]] && { printf 'secrets'; return 0; } ;;
    gpg) [[ "$rest" =~ (--delete-secret-keys|--delete-keys|--delete-secret-and-public-keys) ]] && { printf 'secrets'; return 0; } ;;
    op|bw) [[ "$rest" =~ (^|[[:space:]])(item[[:space:]]+(delete|edit|create)|delete|edit|create)([[:space:]]|$) ]] && { printf 'secrets'; return 0; } ;;
    chown|chgrp|chmod)
      [[ "$rest" =~ (^|[[:space:]])-[a-zA-Z]*R ]] && ! _pp_all_paths_tmp "${w[@]:1}" && [[ "$rest" =~ [[:space:]]/(etc|usr|var|bin|sbin|lib|lib64|boot|opt|srv|root|home|mnt)([[:space:]/]|$) ]] && { printf 'files'; return 0; }
      return 1 ;;

    # ---- publishing ----------------------------------------------------------
    npm) [[ "$rest" =~ ^(publish|unpublish|deprecate|dist-tag[[:space:]]+(add|rm)|owner[[:space:]]+(add|rm)|token[[:space:]]+(create|revoke))([[:space:]]|$) ]] && { printf 'publish'; return 0; } ;;
    twine) [[ "$rest" =~ ^upload ]] && { printf 'publish'; return 0; } ;;
    gem) [[ "$rest" =~ ^(push|yank|owner) ]] && { printf 'publish'; return 0; } ;;
    cargo) [[ "$rest" =~ ^(publish|yank|owner) ]] && { printf 'publish'; return 0; } ;;
    mvn) [[ "$rest" =~ (^|[[:space:]])deploy([[:space:]]|$) ]] && { printf 'publish'; return 0; } ;;
    gradle|gradlew) [[ "$rest" =~ (^|[[:space:]])publish[A-Za-z]*([[:space:]]|$) ]] && { printf 'publish'; return 0; } ;;
    composer) [[ "$rest" =~ ^(publish) ]] && { printf 'publish'; return 0; } ;;
    crane|skopeo|oras) [[ "$rest" =~ ^(push|copy|delete|tag) ]] && { printf 'publish'; return 0; } ;;

    # ---- mail / messaging ----------------------------------------------------
    sendmail|swaks|msmtp|mutt|mailx) printf 'mail'; return 0 ;;
    mail) [[ "$rest" =~ (^|[[:space:]])-s([[:space:]]|$) ]] && { printf 'mail'; return 0; } ;;

    # ---- files and block devices ----------------------------------------------
    rm)
      [[ "$rest" =~ (^|[[:space:]])(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)([[:space:]]|$) ]] || return 1
      _pp_all_paths_tmp "${w[@]:1}" && return 1
      printf 'files'; return 0 ;;
    find)
      [[ "$rest" =~ (^|[[:space:]])(-delete|-exec[[:space:]]+rm|-execdir[[:space:]]+rm|-ok[[:space:]]+rm)([[:space:]]|$) ]] || return 1
      local -a fp=(); local x; for x in "${w[@]:1}"; do [[ "$x" == -* ]] && break; fp+=("$x"); done
      [ "${#fp[@]}" -gt 0 ] && _pp_all_paths_tmp "${fp[@]}" && return 1
      printf 'files'; return 0 ;;
    shred|wipe|srm|wipefs|mkfs|mkfs.*|mkswap|fdisk|sfdisk|parted|sgdisk|cfdisk|zpool|lvremove|vgremove|pvremove) printf 'files'; return 0 ;;
    dd) [[ "$rest" =~ of=/dev/ ]] && { printf 'files'; return 0; } ;;
  esac
  return 1
}

# ---- entry point -----------------------------------------------------------
pp_classify() {
  local cmd="$1" depth="${2:-0}" split seg cls
  [ -n "$cmd" ] || return 1
  # drop trailing comments (a `# --help` after the command must not exempt it),
  # then mark stdin-fed segments before splitting on '|'
  split="$(printf '%s\n' "$cmd" | sed -E 's/(^|[[:space:]])#[^\x27"]*$//' | sed -E 's/\|\|/\n/g; s/&&/\n/g; s/;/\n/g; s/\|/\n@PIPE@ /g; s/\$\(/\n/g; s/`/\n/g; s/\)/ /g; s/\}/ /g')" || return 2
  while IFS= read -r seg; do
    cls="$(_pp_segment "$seg" "$depth")" && { printf '%s\t%s\n' "$cls" "$(_pp_trim "${seg#@PIPE@}")"; return 0; }
  done <<< "$split"
  return 1
}
