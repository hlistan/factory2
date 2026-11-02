#!/usr/bin/env bash
. "$(dirname "$0")/lib.sh"
R="$(new_repo)"
export FACTORY_ROOT="$R"
write_config "$R" 'project:
  default_branch: trunk-x
ship:
  deploy: "make deploy-prod"
  rollback: "make rollback-prod"'

g() { hook "$S/guard-bash.sh" "$(jq -n --arg c "$1" --arg d "$R" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')"; }

g 'git push --force origin main';            t_code 2 "force-push to main"
g 'git push -f origin trunk-x';              t_code 2 "force-push to the configured default branch"
g 'git push origin +release/1.2';            t_code 2 "+refspec to release/*"
g 'git push --force origin factory/x';       t_code 0 "force-push to a feature branch is allowed"
g 'git push origin main';                    t_code 0 "plain push is allowed"
g 'git commit --no-verify -m wip';           t_code 2 "--no-verify"
g 'git commit -nm wip';                      t_code 2 "commit -n"
g 'HUSKY=0 git commit -m x';                 t_code 2 "HUSKY=0"
g 'git commit -m "explain --no-verify"';     t_code 0 "a message mentioning --no-verify"
g 'echo "git push --force origin main"';     t_code 0 "an echo mentioning a force-push"
g 'bash -c "git push --force origin main"';  t_code 2 "bash -c is inspected"
g 'rm -rf ~/';                               t_code 2 "rm -rf home"
g 'rm -rf node_modules';                     t_code 0 "rm -rf a directory"
g 'pkill node';                              t_code 2 "pkill"

g 'make deploy-prod';                        t_code 2 "deploy with no run"
t_has "$ERR" "stage 7" "deploy message names stage 7"
g 'cd app &&   make   deploy-prod';         t_code 2 "deploy with odd spacing"
g 'make rollback-prod';                      t_code 2 "rollback with no run"
g 'make test';                               t_code 0 "other make targets"

g 'command -p git push --force origin main';  t_code 2 "force-push behind command -p"
g 'echo origin | xargs -I{} git push -f {} main'; t_code 2 "force-push behind xargs"
g 'exec -a x git push --force origin main';     t_code 2 "force-push behind exec -a"
g 'command -v git';                             t_code 0 "command -v is harmless"
g 'echo origin | xargs -i git push --force {} main'; t_code 2 "GNU xargs -i takes no separate argument"
g 'echo x | xargs -J % git push -f origin main';     t_code 2 "BSD xargs -J takes one"
g 'echo x | xargs --max-args 1 git push --force origin main'; t_code 2 "GNU long options with a separate value"
bash "$S/state.sh" start demo >/dev/null
g 'make deploy-prod';                        t_code 2 "deploy at stage 1"
bash "$S/state.sh" stage 7 >/dev/null
g 'make deploy-prod';                        t_code 2 "deploy at stage 7 without approval"
bash "$S/state.sh" approve deploy >/dev/null
g 'make deploy-prod';                        t_code 0 "deploy at stage 7 with approval"
bash "$S/state.sh" stage 8 >/dev/null
g 'make deploy-prod';                        t_code 2 "deploy at stage 8"
g 'make rollback-prod';                      t_code 2 "a deploy approval alone doesn't allow a rollback"
bash "$S/state.sh" approve rollback >/dev/null
g 'make rollback-prod';                      t_code 0 "rollback at stage 8 with its own approval"
bash "$S/state.sh" stage 5 >/dev/null
bash "$S/state.sh" stage 7 >/dev/null
g 'make deploy-prod';                        t_code 2 "going back to stage 5 revoked the deploy approval"
g 'make rollback-prod';                      t_code 2 "and the rollback approval"
t_eq "$(jq -c '.approvals | keys' "$R/.factory/runs/$(cat "$R/.factory/runs/active")/state.json")" "[]" "no approvals left"

write_config "$R" 'ship:
  deploy: "..."'
g 'echo ...';                                t_code 0 "placeholder deploy command is ignored"
t_done
