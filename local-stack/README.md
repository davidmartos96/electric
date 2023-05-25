# Fully local development against the ElectricSQL stack

## Running a local stack

Electric services are packaged as docker containers. They can be run locally using the `docker-compose.yaml` file in this directory:

```bash
# Use environment variables from `.envrc` file
source .envrc
docker-compose up
```

This starts 4 containers:

1. Postgres (exposes port 5432 for connections),
2. Vaxine,
3. Electric (exposes port 5133 for websocket connections),

You might encounter errors if any of the specified ports are already taken on your machine - just edit the port binds and keep the new values in mind.

## Developing against the local stack

### Typescript client

Typescript client needs to be configured to connect to the local Electric service. In your electrified app folder, run:

```bash
electric config add_env local
electric config update_env --set-as-default \
                           --replication-disable-ssl \
                           --replication-host 127.0.0.1 \
                           --replication-port 5133 \
                           local
electric build
```
