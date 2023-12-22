
# docker build --no-cache --platform linux/amd64 -t test:1 .


env1=() && for val in `\sops -d test.enc.env | grep -v '#' | head -n3`; do env1+=( -e ${val} ); done && echo $env1

str=$(\sops -d test.enc.env | grep -v '#' | xargs -I {} echo "-e "{} | xargs)

docker run ${env1} -d --name=test_bot test

env1=()
for val in `\sops -d test.enc.env | grep -v '#' | head -n3`
  do env1+=( "-e ${val}" )
done
echo $env1

docker context ls
docker context ls | awk '{print $1}'

#  current user context
old_context=$(docker context ls | grep \* | awk '{print $1}')
#  new user context
context=private-droplet
tag=test
name=test_bot

docker context use ${context}

docker build --no-cache -t ${tag} .

docker build --no-cache -t sputnik_bot:0.9.92 -t sputnik_bot .
docker image prune -f

file=test.enc.env
\sops updatekeys ${file} --yes
\sops exec-file ${file} 'docker run -d -v ${PWD}/usage_logs:/app/usage_logs --env-file {} --restart=always --name=${name} ${tag}'

#\sops exec-file --no-fifo sputnik.enc.env 'docker run -d -v /home/aamite/usage_logs:/app/usage_logs --env-file {} --restart=always --name=sputnik_bot sputnik_bot:0.9.92'

docker rm -f test_bot

# Mongo persistence

#export MONGODB_VERSION=6.0-ubi8
MONGODB_VERSION=6.0-ubi8
#docker run --name mongodb -d mongodb/mongodb-community-server:$MONGODB_VERSION
docker run --name mongodb -d -p 27017:27017 mongodb/mongodb-community-server:$MONGODB_VERSION
docker run --name mongodb -d -p 27017:27017 -v $(pwd)/data:/data/db mongodb/mongodb-community-server:$MONGODB_VERSION
