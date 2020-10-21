#!/usr/bin/env bash

# Check required tools
for tool in wget mvn jq
do
	command -v mvn &> /dev/null || {
		echo "You need to install \"$tool\"!"
		return 1
	}
done

# NOTE: All __roh functions are considered internal.
# 	So you should know how to invoke it correctly if want to use it.
# Unset all existing roh-* and __roh-* functions:
for F in `declare -F | grep -E -w 'roh|__roh' | cut -f 3 -d\ `; do unset -f $F; done

# Variables
# ROH is a short for "RObot Helper"
ROH_DIR=`cd $(dirname "${BASH_SOURCE[0]}"); pwd`
ROH_JAR=target/robothelper-0.0.1-SNAPSHOT.jar
KC_VERSION=4.8.3.Final
KC_AUTH_URL=http://localhost:8080/auth
REALM=demo
CLIENT1_ID=ivr
CLIENT1_SECRET=06b3bef0-37a0-4d2d-9e24-198589d41eec
CLIENT1_SERVICE_ACCOUNT=service-account-$CLIENT1_ID
CLIENT2_ID=$CLIENT1_ID-web
CURL_RESPONSE=$ROH_DIR/curl.response.txt
CURL_LOG=$ROH_DIR/curl.log

export PATH="$ROH_DIR/keycloak/bin:$PATH"

roh-jwt() {
	jq -sR 'split(".")[0,1] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson
		| if has("exp")       then .exp       |= todate else . end
		| if has("iat")       then .iat       |= todate else . end
		| if has("nbf")       then .nbf       |= todate else . end
		| if has("auth_time") then .auth_time |= todate else . end' "$@"
}

roh-h2-console() {
	set -x
	jar="./modules/system/layers/base/com/h2database/h2/main/h2-*.jar"
	url="jdbc:h2:./standalone/data/keycloak;AUTO_SERVER=TRUE"
	(cd "$ROH_DIR/keycloak"; java -cp $jar org.h2.tools.Console -url "$url" -user sa -password sa)
	set +x
}

roh-kc-install() {
	cd "$ROH_DIR"
	local d
	for d in $(find . -maxdepth 1 -type d -name 'keycloak*')
	do
		echo "Removing directory $d ..."
		rm -rf "$d"
	done
	local keycloak=keycloak-$KC_VERSION.tar.gz
	if [ ! -f $keycloak ]
	then
		echo Downloading $keycloak ...
		wget -c https://downloads.jboss.org/keycloak/$KC_VERSION/$keycloak
	fi
	echo Extracting $keycloak ...
	tar xfz $keycloak
	echo Creating link keycloak ...
	ln -sf ${keycloak%.tar.gz} keycloak
	cd "$OLDPWD"
	echo Adding "admin" user. Please, use "admin" for the asked password below:
	add-user-keycloak.sh -u admin
}

roh-kc-start() {
	standalone.sh &> /dev/null &
}

roh-kc-log() {
	tail -f "$ROH_DIR"/keycloak/standalone/log/server.log
}

roh-kc-increase-log-level() {
	jboss-cli.sh --connect <<-EOF
	batch
	/subsystem=logging/logger=org.keycloak/:add(category=org.keycloak,level=TRACE)
	/subsystem=logging/logger=org.keycloak.transaction/:add(category=org.keycloak.transaction,level=INFO)
	/subsystem=logging/logger=org.keycloak.services.scheduled/:add(category=org.keycloak.services.scheduled,level=INFO)
	/subsystem=logging/logger=org.keycloak.models.sessions.infinispan/:add(category=org.keycloak.models.sessions.infinispan,level=INFO)
	/subsystem=logging/logger=org.keycloak.connections.jpa/:add(category=org.keycloak.connections.jpa,level=DEBUG)
	/subsystem=logging/logger=com.paulojeronimo/:add(category=com.paulojeronimo,level=TRACE)
	run-batch
	EOF
}

roh-kc-reset-log-level() {
	jboss-cli.sh --connect <<-EOF
	batch
	/subsystem=logging/logger=org.keycloak:remove
	/subsystem=logging/logger=org.keycloak.transaction:remove
	/subsystem=logging/logger=org.keycloak.services.scheduled:remove
	/subsystem=logging/logger=org.keycloak.models.sessions.infinispan:remove
	/subsystem=logging/logger=org.keycloak.connections.jpa:remove
	/subsystem=logging/logger=com.paulojeronimo:remove
	run-batch
	EOF
}

roh-kc-configure() {
	kcadm.sh config credentials --server $KC_AUTH_URL --realm master --user admin --password admin
	kcadm.sh create realms -s realm=$REALM -s enabled=true
	kcadm.sh create users -r $REALM -s username=user1 -s enabled=true
	echo Adding client \"$CLIENT1_ID\"
	kcadm.sh create clients -r $REALM -s clientId=$CLIENT1_ID -s enabled=true -s clientAuthenticatorType=client-secret -s secret=$CLIENT1_SECRET -s 'redirectUris=["*"]'  -s serviceAccountsEnabled=true
	kcadm.sh add-roles -r $REALM --uusername $CLIENT1_SERVICE_ACCOUNT --cclientid realm-management --rolename manage-users --rolename view-users
	echo Adding client \"$CLIENT2_ID\"
	kcadm.sh create clients -r $REALM -s clientId=$CLIENT2_ID -s enabled=true -s publicClient=true -s baseUrl=http://localhost:8080 -s directAccessGrantsEnabled=true 
	echo Doing configurations for user attendant1
	kcadm.sh create users -r $REALM -s username=attendant1 -s enabled=true
	kcadm.sh set-password -r $REALM --username attendant1 --new-password attendant1
	kcadm.sh create roles -r $REALM -s name=$CLIENT1_ID-attendant -s 'description=IVR Attendant'
	kcadm.sh add-roles -r $REALM --uusername attendant1 --rolename $CLIENT1_ID-attendant
}

roh-deploy() {
	local deploy_dir=keycloak/standalone/deployments
	local mvn_log=mvn.log
	cd "$ROH_DIR"
	[ "$1" = "-f" ] && rm $ROH_JAR
	[ -d "$deploy_dir" ] || {
		echo "$deploy_dir does not exists!"
		return 1
	}
	[ -f $ROH_JAR ] || {
		echo "Building (using your maven) ..."
		mvn clean package &> $mvn_log
	}
	[ $? = 0 ] && {
		echo "Copying $ROH_JAR to $deploy_dir ..."
		cp $ROH_JAR "$deploy_dir"
	} || {
		echo -e "Build failed:\n$(cat $mvn_log)"
	}
	cd "$OLDPWD"
}

__roh-print-ok-or-failed() {
	local last_status=$?
	[ $last_status = 0 ] && echo Ok || {
		echo -e "Failed! Details:\n$(cat $CURL_LOG)"
		return $last_status
	}
}

__roh-curl() {
	curl -s -o $CURL_RESPONSE -w "%{http_code}" "$@"
}

__roh-print-ok-or-failed-2() {
	local last_status=$?
	local response_code=$1
	local expected=$2
	[ $last_status = 0 ] && {
		[ $response_code = $expected ] && {
			echo "Ok! The expected code was $expected."
		} || {
			echo "Failed! Responde code ($response_code) wasn't the expected ($expected)."
			return 1
		}
	} || {
		echo -e "Curl failed! Details:\n$(cat $CURL_LOG)"
		return $last_status
	}
}

__roh-service-account-access_token() {
	local file=$ROH_DIR/$CLIENT1_SERVICE_ACCOUNT.access.token
	[ -f "$file" ] && {
		echo "File \"$file\" already exists and contains a token for \"$CLIENT1_SERVICE_ACCOUNT\". Using it!"
	} || {
		echo -n "Generating an access_token for \"$CLIENT1_SERVICE_ACCOUNT\" ... "
		(set -o pipefail && curl -H 'Content-Type: application/x-www-form-urlencoded' \
			-d "grant_type=client_credentials" \
			-d "client_id=$CLIENT1_ID" \
			-d "client_secret=$CLIENT1_SECRET" \
			-X POST "$KC_AUTH_URL/realms/$REALM/protocol/openid-connect/token" \
			2> "$CURL_LOG" | jq -r .access_token > "$file")
		__roh-print-ok-or-failed
	}
	client1_service_account_access_token=`cat "$file"`
}

__roh-create-user() {
	local access_token=$1
	local user=$2
	local password=$3
	local endpoint="$CLIENT1_ID/create-user"
	local response_code
	echo -n "Creating user \"$user\" with \"$password\" by calling endpoint \"$endpoint\" ... "
	response_code=$(__roh-curl -X POST "$KC_AUTH_URL/realms/$REALM/$endpoint" \
		-H 'Content-Type: application/x-www-form-urlencoded' \
		-H "Authorization: Bearer $access_token" \
		-d "username=$user" \
		-d "password=$password" 2> "$CURL_LOG")
	__roh-print-ok-or-failed-2 $response_code 200 || return $?
	echo "Result:"
	cat $CURL_RESPONSE | jq .
}

__roh-login-on-client2-as-user() {
	local user=$1
	local password=$2
	local response_code
	echo -n "Trying to login on \"$CLIENT2_ID\" with user \"$user\" and password \"$password\" ... "
	response_code=$(__roh-curl -X POST "$KC_AUTH_URL/realms/$REALM/protocol/openid-connect/token" \
		-H 'Content-Type: application/x-www-form-urlencoded' \
		-d "grant_type=password&client_id=$CLIENT2_ID&username=$user&password=$password" \
		2> "$CURL_LOG")
	__roh-print-ok-or-failed-2 $response_code 200 || return $?
	echo $result > "$ROH_DIR"/$user.access.token
}

roh-delete-generated-tokens() {
	find "$ROH_DIR" -type f -name '*.token' -delete
}

__roh-create-and-login() {
	local user=$1
	local password=$2
	__roh-create-user $client1_service_account_access_token $user $password
 	__roh-login-on-client2-as-user $user $password
}

roh-test-create-user() {
	__roh-service-account-access_token || return $?
	local id
	for id in {2..4}; do __roh-create-and-login user$id password$id; done
}
