#!/bin/bash

DOCKER_COMPOSE_FILE="docker-compose.rolling.yaml"
echo "[DEBUG] Using Docker Compose file: $DOCKER_COMPOSE_FILE"
echo "[DEBUG] Extracting services from $DOCKER_COMPOSE_FILE"
# Supports both list format (- "traefik.enable=true") and map format (traefik.enable: "true")
services=$(yq eval '.services | to_entries[] | select(
  .value.labels["traefik.enable"]? == "true" or
  .value.labels[]? == "traefik.enable=true"
) | .key' "$DOCKER_COMPOSE_FILE")
echo "[DEBUG] Services detected: $services"
service_ips=""

# Getting containers IP-addresses
for service in $services; do
  echo "[DEBUG] Checking service: $service"
  container_ids=$(docker compose -f "$DOCKER_COMPOSE_FILE" ps -q "$service" | cut -c1-12)
  echo "[DEBUG] Containers for $service: $container_ids"
  for container_id in $container_ids; do
    container_ip=$container_id
    echo "[DEBUG] Container: $container_id, IP: $container_ip"
    if [ -n "$container_ip" ]; then
      service_ips="${service_ips}${service}:${container_ip} "
    fi
  done
done
echo "[DEBUG] Final service_ips: $service_ips"
if [ -z "$service_ips" ]; then
  echo "Error: The list of IP addresses is empty!"
  exit 1
fi
echo "[DEBUG] Fetching container labels"
# Get Traefik-labels and generate YAML
docker ps -q | xargs -I {} docker inspect --format '{{json .Config.Labels}}' {} | jq -s --arg service_ips "$service_ips" '
  def split_ips:
    reduce ($service_ips | split(" "))[] as $item ({};
      if ($item | contains(":")) then
        . + { ($item | split(":")[0]): (.[$item | split(":")[0]] + [ $item | split(":")[1] ] // []) }
      else . end
    );

  # Convert a dot-notation string with optional [n] indices to a jq path array.
  # e.g. "tls.domains[0].main" -> ["tls","domains",0,"main"]
  def to_nested_path:
    gsub("\\[(?<n>[0-9]+)\\]"; ".\(.n)")
    | split(".")
    | map(if test("^[0-9]+$") then tonumber else . end);

  # Coerce string values to their natural types for config output.
  def coerce_value:
    if . == "true" then true
    elif . == "false" then false
    elif (. != "" and test("^-?[0-9]+$")) then tonumber
    else . end;

  # Split a comma-separated string into a trimmed array.
  def csv_to_array:
    split(",") | map(gsub("^\\s+"; "") | gsub("\\s+$"; ""));

  def extract_health_check(item):
    if (
      (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.path"] // "") == "" and
      (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.interval"] // "") == "" and
      (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.timeout"] // "") == "" and
      (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.scheme"] // "") == "" and
      (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.mode"] // "") == "" and
      (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.hostname"] // "") == "" and
      (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.port"] // "") == "" and
      (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.followRedirects"] // "") == "" and
      (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.method"] // "") == "" and
      (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.status"] // "") == ""
    ) then
      null
    else
      {
        path: (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.path"] // ""),
        interval: (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.interval"] // ""),
        timeout: (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.timeout"] // ""),
        scheme: (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.scheme"] // ""),
        mode: (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.mode"] // ""),
        hostname: (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.hostname"] // ""),
        port: (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.port"] // ""),
        followRedirects: (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.followRedirects"] // ""),
        method: (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.method"] // ""),
        status: (item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.status"] // ""),
        headers: (
          item | to_entries |
          map(select(.key | startswith("traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.healthCheck.headers."))) |
          map({
            key: (.key | split(".") | .[-1]),
            value: .value
          }) |
          from_entries
        ),
      } | with_entries(select(.value != "" and .value != {}))

    end;

  def extract_sticky(item):
    ( item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.sticky.cookie"] // "" ) as $enabled |
    ( item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.sticky.cookie.name"] // "" ) as $name |
    ( item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.sticky.cookie.secure"] // "" ) as $secure |
    ( item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.sticky.cookie.httpOnly"] // "" ) as $httpOnly |
    ( item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.sticky.cookie.sameSite"] // "" ) as $sameSite |
    ( item["traefik.http.services." + item["com.docker.compose.service"] + ".loadbalancer.sticky.cookie.maxAge"] // "" ) as $maxAge |
    if ($enabled == "" and $name == "" and $secure == "" and $httpOnly == "" and $sameSite == "" and $maxAge == "") then
      null
    else
      { cookie: (
          {}
          | if $name != "" then . + { name: $name } else . end
          | if $secure != "" then . + { secure: ($secure == "true") } else . end
          | if $httpOnly != "" then . + { httpOnly: ($httpOnly == "true") } else . end
          | if $sameSite != "" then . + { sameSite: $sameSite } else . end
          | if $maxAge != "" then . + { maxAge: ($maxAge | tonumber) } else . end
        )
      }
    end;

  reduce .[] as $item ({};
    ($item["com.docker.compose.service"]) as $svc |
    if ($svc | in(split_ips)) then
      debug("Service: \($svc)", "") |
      debug("Labels: \($item | tostring)", "") |

      # ── HTTP Router ────────────────────────────────────────────────────

      debug("Rule: \($item["traefik.http.routers.\($svc).rule"] | tostring)", "") |
      debug("EntryPoints: \($item["traefik.http.routers.\($svc).entrypoints"] // "none")", "") |
      debug("Middlewares: \($item["traefik.http.routers.\($svc).middlewares"] // "none")", "") |
      debug("Router TLS: \($item["traefik.http.routers.\($svc).tls"] // "none")", "") |
      debug("Router TLS certresolver: \($item["traefik.http.routers.\($svc).tls.certresolver"] // "none")", "") |

      .http.routers[$svc].rule = ($item["traefik.http.routers.\($svc).rule"] // null) |
      .http.routers[$svc].service = ($item["traefik.http.routers.\($svc).service"] // $svc) |

      (($item["traefik.http.routers.\($svc).entrypoints"] // "") as $ep |
        if $ep != "" then .http.routers[$svc].entryPoints = ($ep | csv_to_array) else . end
      ) |
      (($item["traefik.http.routers.\($svc).middlewares"] // "") as $mw |
        if $mw != "" then .http.routers[$svc].middlewares = ($mw | csv_to_array) else . end
      ) |
      (($item["traefik.http.routers.\($svc).priority"] // "") as $pri |
        if $pri != "" then .http.routers[$svc].priority = ($pri | tonumber) else . end
      ) |

      # TLS — generic: handles tls, tls.certresolver, tls.options,
      #   tls.domains[n].main, tls.domains[n].sans, etc.
      ( . as $state |
        [ $item | to_entries[] | select(.key | startswith("traefik.http.routers.\($svc).tls")) ] |
        if length > 0 then
          reduce .[] as $e (
            $state;
            if $e.key == "traefik.http.routers.\($svc).tls" then
              if ($e.value == "true" and (.http.routers[$svc].tls == null)) then
                .http.routers[$svc].tls = {}
              else . end
            else
              ( $e.key | ltrimstr("traefik.http.routers.\($svc).") | to_nested_path ) as $path |
              setpath(["http","routers",$svc] + $path; ($e.value | coerce_value))
            end
          )
        else $state end
      ) |

      # ── HTTP Service ───────────────────────────────────────────────────

      debug("Server port: \($item["traefik.http.services.\($svc).loadbalancer.server.port"] // "80")", "") |
      debug("Server scheme: \($item["traefik.http.services.\($svc).loadbalancer.server.scheme"] // "http")", "") |
      debug("passHostHeader: \($item["traefik.http.services.\($svc).loadbalancer.passhostheader"] // "none")", "") |
      debug("responseForwarding.flushInterval: \($item["traefik.http.services.\($svc).loadbalancer.responseforwarding.flushinterval"] // "none")", "") |

      (($item["traefik.http.services.\($svc).loadbalancer.server.scheme"] // "http") as $scheme |
        .http.services[$svc].loadBalancer.servers =
          (split_ips[$svc] | map({url: ($scheme + "://" + . + ":" + ($item["traefik.http.services.\($svc).loadbalancer.server.port"] // "80"))}))
      ) |

      (($item["traefik.http.services.\($svc).loadbalancer.passhostheader"] // "") as $pph |
        if $pph != "" then .http.services[$svc].loadBalancer.passHostHeader = ($pph == "true") else . end
      ) |
      (($item["traefik.http.services.\($svc).loadbalancer.responseforwarding.flushinterval"] // "") as $fi |
        if $fi != "" then .http.services[$svc].loadBalancer.responseForwarding.flushInterval = $fi else . end
      ) |

      debug("HealthCheck Path: \($item["traefik.http.services." + $svc + ".loadbalancer.healthCheck.path"] // "none")", "") |
      debug("HealthCheck Interval: \($item["traefik.http.services." + $svc + ".loadbalancer.healthCheck.interval"] // "none")", "") |
      debug("HealthCheck Timeout: \($item["traefik.http.services." + $svc + ".loadbalancer.healthCheck.timeout"] // "none")", "") |
      debug("Extracting headers for service: \($svc)", "") |
      debug("Headers: \($item | to_entries | map(select(.key | startswith("traefik.http.services." + $svc + ".loadbalancer.healthCheck.headers."))) | .[] | "\(.key) = \(.value)")", "") |

      debug("Calling extract_health_check for service: \($svc)", "") |
      (extract_health_check($item) as $hc |
        if $hc then
          .http.services[$svc].loadBalancer += { healthCheck: $hc }
        else
          .
        end
      ) |

      debug("Sticky cookie enabled: \($item["traefik.http.services." + $svc + ".loadbalancer.sticky.cookie"] // "none")", "") |
      debug("Sticky cookie name: \($item["traefik.http.services." + $svc + ".loadbalancer.sticky.cookie.name"] // "none")", "") |
      debug("Sticky cookie secure: \($item["traefik.http.services." + $svc + ".loadbalancer.sticky.cookie.secure"] // "none")", "") |
      debug("Sticky cookie httpOnly: \($item["traefik.http.services." + $svc + ".loadbalancer.sticky.cookie.httpOnly"] // "none")", "") |
      debug("Sticky cookie sameSite: \($item["traefik.http.services." + $svc + ".loadbalancer.sticky.cookie.sameSite"] // "none")", "") |
      debug("Sticky cookie maxAge: \($item["traefik.http.services." + $svc + ".loadbalancer.sticky.cookie.maxAge"] // "none")", "") |

      debug("Calling extract_sticky for service: \($svc)", "") |
      (extract_sticky($item) as $sticky |
        if $sticky then
          debug("Sticky session found, applying config: \($sticky | tostring)", "") |
          .http.services[$svc].loadBalancer += { sticky: $sticky }
        else
          debug("No sticky session labels found for service: \($svc)", "") |
          .
        end
      ) |

      # ── HTTP Middlewares (generic) ─────────────────────────────────────

      ( . as $state |
        [ $item | keys[] | select(startswith("traefik.http.middlewares.")) | split(".")[3] ] | unique |
        reduce .[] as $mw_name ($state;
          debug("Middleware detected: \($mw_name)", "") |
          (
            $item | to_entries |
            map(select(.key | startswith("traefik.http.middlewares.\($mw_name)."))) |
            reduce .[] as $e (
              {};
              debug("Middleware \($mw_name) label: \($e.key) = \($e.value)", "") |
              ( $e.key | ltrimstr("traefik.http.middlewares.\($mw_name).") | to_nested_path ) as $path |
              setpath($path; ($e.value | coerce_value))
            )
          ) as $mw_config |
          if ($mw_config | length) > 0 then
            debug("Middleware \($mw_name) config: \($mw_config | tostring)", "") |
            .http.middlewares[$mw_name] = $mw_config
          else . end
        )
      ) |

      # ── TCP ────────────────────────────────────────────────────────────

      ( . as $state |
        [ $item | keys[] | select(startswith("traefik.tcp.routers.")) | split(".")[3] ] | unique |
        reduce .[] as $tcp_name ($state;
          ( ($item["traefik.tcp.routers.\($tcp_name).rule"] // "") as $tcp_rule
          | ($item["traefik.tcp.routers.\($tcp_name).service"] // $tcp_name) as $tcp_svc
          | ($item["traefik.tcp.services.\($tcp_svc).loadbalancer.server.port"] // "") as $tcp_port
          | (($item["traefik.tcp.routers.\($tcp_name).entrypoints"] // "") | if . == "" then [] else csv_to_array end) as $tcp_ep
          | ($item["traefik.tcp.routers.\($tcp_name).middlewares"] // "") as $tcp_mw
          | ($item["traefik.tcp.routers.\($tcp_name).tls"] // "") as $tcp_tls
          | ($item["traefik.tcp.routers.\($tcp_name).tls.passthrough"] // "") as $tcp_pt
          | ($item["traefik.tcp.routers.\($tcp_name).tls.certresolver"] // "") as $tcp_cr
          | ($item["traefik.tcp.routers.\($tcp_name).tls.options"] // "") as $tcp_opts
          | ($item["traefik.tcp.services.\($tcp_svc).loadbalancer.terminationdelay"] // "") as $tcp_td
          | ($item["traefik.tcp.services.\($tcp_svc).loadbalancer.proxyprotocol.version"] // "") as $tcp_pp
          | debug("TCP router: \($tcp_name), rule: \($tcp_rule), port: \($tcp_port)", "") |
          if $tcp_rule != "" and $tcp_port != "" then
            .tcp.routers[$tcp_name] = (
              { rule: $tcp_rule, service: $tcp_svc }
              + (if ($tcp_ep | length) > 0 then { entryPoints: $tcp_ep } else {} end)
              + (if $tcp_mw != "" then { middlewares: ($tcp_mw | csv_to_array) } else {} end)
            ) |
            ( if $tcp_tls == "true" or $tcp_pt != "" or $tcp_cr != "" or $tcp_opts != "" then
                debug("TCP TLS enabled for router: \($tcp_name)", "") |
                .tcp.routers[$tcp_name].tls = (
                  {}
                  | if $tcp_pt == "true" then . + { passthrough: true } else . end
                  | if $tcp_cr != "" then . + { certResolver: $tcp_cr } else . end
                  | if $tcp_opts != "" then . + { options: $tcp_opts } else . end
                )
              else . end
            ) |
            .tcp.services[$tcp_svc].loadBalancer.servers = (split_ips[$svc] | map({ address: (. + ":" + $tcp_port) })) |
            ( if $tcp_td != "" then
                debug("TCP terminationDelay: \($tcp_td)", "") |
                .tcp.services[$tcp_svc].loadBalancer.terminationDelay = ($tcp_td | tonumber)
              else . end
            ) |
            ( if $tcp_pp != "" then
                debug("TCP proxyProtocol version: \($tcp_pp)", "") |
                .tcp.services[$tcp_svc].loadBalancer.proxyProtocol.version = ($tcp_pp | tonumber)
              else . end
            )
          else .
          end
          )
        )
      ) |

      # ── UDP ────────────────────────────────────────────────────────────

      ( . as $state |
        [ $item | keys[] | select(startswith("traefik.udp.routers.")) | split(".")[3] ] | unique |
        reduce .[] as $udp_name ($state;
          ( ($item["traefik.udp.routers.\($udp_name).service"] // $udp_name) as $udp_svc
          | ($item["traefik.udp.services.\($udp_svc).loadbalancer.server.port"] // "") as $udp_port
          | (($item["traefik.udp.routers.\($udp_name).entrypoints"] // "") | if . == "" then [] else csv_to_array end) as $udp_ep
          | debug("UDP router: \($udp_name), port: \($udp_port)", "") |
          if $udp_port != "" then
            .udp.routers[$udp_name] = (
              { service: $udp_svc }
              + (if ($udp_ep | length) > 0 then { entryPoints: $udp_ep } else {} end)
            ) |
            .udp.services[$udp_svc].loadBalancer.servers = (split_ips[$svc] | map({ address: (. + ":" + $udp_port) }))
          else .
          end
          )
        )
      )

    else . end
  )' | yq -P
