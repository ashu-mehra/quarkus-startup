#!/bin/bash

docker run -d --cpuset-cpus=4-7 --cpuset-mems=0  --ulimit memlock=-1:-1 -it --rm=true --memory-swappiness=0 --name postgres-quarkus-rest-http-crud -e POSTGRES_USER=restcrud -e POSTGRES_PASSWORD=restcrud -e POSTGRES_DB=rest-crud -p 5432:5432 postgres:10.5
