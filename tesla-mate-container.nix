{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.teslaMateContainer;

  hostSecrets = config.fudo.secrets.host-secrets."${config.instance.hostname}";

  makeEnvFile = envVars:
    let
      envLines =
        mapAttrsToList (var: val: ''${var}="${toString val}"'') envVars;
    in pkgs.writeText "envFile" (concatStringsSep "\n" envLines);

  makeTeslaMateImage = { teslaMateImage, postgresImage, grafanaImage
    , teslaMatePort, grafanaPort, teslaMateEnvFile, postgresEnvFile
    , grafanaEnvFile, teslaMateUid, postgresUid, grafanaUid, stateDirectory, ...
    }:
    { pkgs, ... }: {
      project.name = "teslamate";
      services = {
        teslamate = {
          service = {
            image = teslaMateImage;
            restart = "always";
            ports = [ "${toString teslaMatePort}:4000" ];
            env_file = [ teslaMateEnvFile ];
            capabilities.ALL = false;
            depends_on.postgres.condition = "service_healthy";
          };
        };
        postgres = {
          service = {
            image = postgresImage;
            restart = "always";
            volumes = [ "${stateDirectory}/postgres:/var/lib/postgresql/data" ];
            env_file = [ postgresEnvFile ];
            user = "${toString postgresUid}:${toString postgresUid}";
            healthcheck = {
              test = [ "CMD" "pg_isready" "-U" "teslamate" "-d" "teslamate" ];
              start_period = "20s";
              interval = "30s";
              retries = 5;
              timeout = "3s";
            };
          };
        };
        grafana = {
          service = {
            image = grafanaImage;
            restart = "always";
            volumes = [ "${stateDirectory}/grafana:/var/lib/grafana" ];
            env_file = [ grafanaEnvFile ];
            user = "${toString grafanaUid}:${toString grafanaUid}";
            ports = [ "${toString grafanaPort}:3000" ];
            depends_on = [ "teslamate" ];
          };
        };
      };
    };
in {
  options.services.teslaMateContainer = with types; {
    enable = mkEnableOption "Enable TeslaMate in a PodMan container.";

    images = {
      tesla-mate = mkOption {
        type = str;
        description = "Docker image to use for Tesla Mate.";
        default = "teslamate/teslamate:latest";
      };
      postgres = mkOption {
        type = str;
        description = "Docker image to use for Postgres DB.";
        default = "postgres:15";
      };
      grafana = mkOption {
        type = str;
        description = "Docker image to use for Grafana.";
        default = "teslamate/grafana:latest";
      };
    };

    mqtt = {
      host = mkOption {
        type = str;
        description = "Hostname of the MQTT server.";
      };
      port = mkOption {
        type = port;
        description = "Port of the MQTT server";
        default = 1883;
      };
      user = mkOption {
        type = str;
        description = "User as which to connect to the MQTT server.";
        default = "tesla-mate";
      };
      password = mkOption {
        type = str;
        description =
          "Password with which to authenticate with the MQTT server.";
      };
    };

    port = mkOption {
      type = port;
      description = "Local port on which to listen for TeslaMate requests.";
    };

    grafana-port = mkOption {
      type = port;
      description = "Local port on which to listen for Grafana requests.";
    };

    state-directory = mkOption {
      type = str;
      description = "Path at which to store service state.";
    };
  };

  config = mkIf cfg.enable {
    fudo.secrets.host-secrets."${config.instance.hostname}" = let
      teslaMateDbPass = readFile
        (pkgs.lib.passwd.stablerandom-passwd-file "teslaMateDbPasswd"
          config.instance.build-seed);
      teslaMateEncryptionKey = readFile
        (pkgs.lib.passwd.stablerandom-passwd-file "teslaMateEncryptionKey"
          config.instance.build-seed);
    in {
      teslaMateEnv = {
        source-file = makeEnvFile {
          ENCRYPTION_KEY = teslaMateEncryptionKey;
          DATABASE_USER = "teslamate";
          DATABASE_PASS = teslaMateDbPass;
          DATABASE_HOST = "postgres";
          DATABASE_NAME = "teslamate";
          MQTT_HOST = cfg.mqtt.host;
          MQTT_PORT = cfg.mqtt.port;
          MQTT_USERNAME = cfg.mqtt.user;
          MQTT_PASSWORD = cfg.mqtt.password;
        };
        target-file = "/run/tesla-mate/tesla-mate.env";
      };
      teslaMatePostgresEnv = {
        source-file = makeEnvFile {
          POSTGRES_USER = "teslamate";
          POSTGRES_PASSWORD = teslaMateDbPass;
          POSTGRES_DB = "teslamate";
        };
        target-file = "/run/tesla-mate/postgres.env";
      };
      teslaMateGrafanaEnv = {
        source-file = makeEnvFile {
          DATABASE_USER = "teslamate";
          DATABASE_PASS = teslaMateDbPass;
          DATABASE_NAME = "teslamate";
          DATABASE_HOST = "postgres";
        };
        target-file = "/run/tesla-mate/grafana.env";
      };
    };

    users = {
      users = {
        tesla-mate = {
          isSystemUser = true;
          group = "tesla-mate";
          uid = 720;
        };
        tesla-mate-postgres = {
          isSystemUser = true;
          group = "tesla-mate";
          uid = 721;
        };
        tesla-mate-grafana = {
          isSystemUser = true;
          group = "tesla-mate";
          uid = 722;
        };
      };
      groups.tesla-mate.members =
        [ "tesla-mate" "tesla-mate-postgres" "tesla-mate-grafana" ];
    };

    systemd = {
      tmpfiles.rules = [
        "d ${cfg.state-directory}/import 0700 ${
          toString config.users.users.tesla-mate.uid
        } root - -"
        "d ${cfg.state-directory}/postgres 0700 ${
          toString config.users.users.tesla-mate-postgres.uid
        } root - -"
        "d ${cfg.state-directory}/grafana 0700 ${
          toString config.users.users.tesla-mate-grafana.uid
        } root - -"
      ];

      services.arion-teslamate = {
        after =
          [ "fudo-secrets.target" "network-online.target" "podman.service" ];
        requires = [ "network-online.target" "podman.service" ];
      };
    };

    virtualisation.arion.projects.teslamate.settings = let
      teslaMateImage = makeTeslaMateImage {
        teslaMateImage = cfg.images.tesla-mate;
        postgresImage = cfg.images.postgres;
        grafanaImage = cfg.images.grafana;
        teslaMatePort = cfg.port;
        grafanaPort = cfg.grafana-port;
        stateDirectory = cfg.state-directory;
        teslaMateEnvFile = hostSecrets.teslaMateEnv.target-file;
        postgresEnvFile = hostSecrets.teslaMatePostgresEnv.target-file;
        grafanaEnvFile = hostSecrets.teslaMateGrafanaEnv.target-file;
        teslaMateUid = config.users.users.tesla-mate.uid;
        postgresUid = config.users.users.tesla-mate-postgres.uid;
        grafanaUid = config.users.users.tesla-mate-grafana.uid;
      };
    in { imports = [ teslaMateImage ]; };
  };
}
