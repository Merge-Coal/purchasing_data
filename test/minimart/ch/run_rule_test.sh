#!/usr/bin/env bash
# The sensitive-column rule exists twice, in two regex dialects: in db/minimart_ro_grants.sql (Postgres,
# decides what minimart_ro may READ) and in scripts/minimart_gen_schema.sh (ClickHouse RE2, decides what the
# mirror SELECTS). They must agree on every name, or either a secret is mirrored or a column that is not a secret
# is lost. This test creates one table with many column names, runs the real grants file, asks the real planner,
# and compares: planner `sensitive` == role cannot read the column. Also checks the constants are textually identical.
#   bash test/minimart/ch/run_rule_test.sh        (ports 19304/18304, Postgres prefix mmc_c)
source "$(dirname "$0")/lib.sh"
mm_env c 19304 18304

NAMES="password passwd passphrase pass_phrase user_password PasswordHash password_hash hash hashtag api_token apiToken access_token tokenizer refresh_token secret client_secret secretNote api_key apiKey API_KEY apikey api-key private_key privateKey credential credentials card_number cardNumber cardno card_num cardinal card_type card discard credit_card otp reset_otp OTP footprint pin pin_code user_pin pincode PIN shipping shipping_address spinach opinion pinned pinyin pwd db_pwd salt salty saltine cvv cvc cvc_code checksum category description name email phone price created_at updated_at note notes address tokens_used"

echo "== setup =="
PGSU "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$PGDB' AND pid <> pg_backend_pid()" >/dev/null 2>&1
dropdb --if-exists "$PGDB" 2>/dev/null; createdb "$PGDB" || { bad "createdb"; mm_summary; exit 1; }
{ echo "CREATE TABLE rule_probe (id integer PRIMARY KEY"; for n in $NAMES; do printf ', "%s" text' "$n"; done; echo ");"; } > "$WORK/out/probe.sql"
PGF "$WORK/out/probe.sql" && ok "probe table with $(echo $NAMES | wc -w | tr -d ' ') columns created"
mm_ro_role
mm_ch_start

echo "== the constants are identical in both files =="
g_sub=$(sed -n "s/^\\\\set deny_substr[[:space:]]*'\\(.*\\)'.*/\\1/p" db/minimart_ro_grants.sql | head -1)
g_word=$(sed -n "s/^\\\\set deny_word[[:space:]]*'\\(.*\\)'.*/\\1/p" db/minimart_ro_grants.sql | head -1)
c_sub=$(sed -n "s/^DENY_SUBSTR='\\(.*\\)'\$/\\1/p" scripts/minimart_gen_schema.sh | head -1)
c_word=$(sed -n "s/^DENY_WORD='\\(.*\\)'\$/\\1/p" scripts/minimart_gen_schema.sh | head -1)
[[ -n "$g_sub" && -n "$g_word" ]] && ok "grants file defines deny_substr and deny_word" || bad "could not read the constants from db/minimart_ro_grants.sql"
check "deny_substr identical" "$g_sub" "$c_sub"
check "deny_word identical" "$g_word" "$c_word"

echo "== planner vs role =="
"$GEN" --cols | CH --multiquery --format TSVRaw > "$WORK/out/cols.tsv" 2> "$WORK/out/cols.err"
[[ -s "$WORK/out/cols.tsv" ]] && ok "planner answered" || { bad "planner failed: $(head -c 300 "$WORK/out/cols.err")"; mm_summary; exit 1; }
disagree=0; n=0
for col in $NAMES; do
  n=$((n+1))
  planner=$(awk -F'\t' -v c="$col" '$1 == "rule_probe" && $2 == c { print $7 }' "$WORK/out/cols.tsv")
  readable=$(PGS "SELECT has_column_privilege('$RO_ROLE', 'rule_probe', '$col', 'SELECT')")
  want=1; [[ "$readable" == t ]] && want=0
  if [[ "$planner" != "$want" ]]; then disagree=$((disagree+1)); bad "column '$col': planner sensitive=$planner, role readable=$readable"; fi
done
[[ $disagree -eq 0 ]] && ok "planner and grants agree on all $n column names"
sens=$(awk -F'\t' '$1 == "rule_probe" && $7 == 1 { n++ } END { print n + 0 }' "$WORK/out/cols.tsv")
[[ $sens -ge 20 && $sens -lt $n ]] && ok "the rule is neither empty nor everything ($sens of $n sensitive)" || bad "implausible number of sensitive columns: $sens of $n"
mm_summary
