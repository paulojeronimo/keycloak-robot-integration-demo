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
CURL_LOG=$ROH_DIR/curl.log

export PATH="$ROH_DIR/keycloak/bin:$PATH"

roh-jwt() {
	jq -sR 'split(".")[0,1] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson
		| if has("exp")       then .exp       |= todate else . end
		| if has("iat")       then .iat       |= todate else . end
		| if has("nbf")       then .nbf       |= todate else . end
		| if has("auth_time") then .auth_time |= todate else . end' "$@"
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
	local result
	echo -n "Creating user \"$user\" with \"$password\" by calling endpoint \"$endpoint\" ... "
	result=$(curl -X POST "$KC_AUTH_URL/realms/$REALM/$endpoint" \
		-H 'Content-Type: application/x-www-form-urlencoded' \
		-H "Authorization: Bearer $access_token" \
		-d "username=$user" \
		-d "password=$password" 2> "$CURL_LOG")
	__roh-print-ok-or-failed || return $?
	echo "Result:"
	jq . <<< $result
}

__roh-login-on-client2-as-user() {
	local user=$1
	local password=$2
	local result
	echo -n "Trying to login on \"$CLIENT2_ID\" with user \"$user\" and password \"$password\" ... "
	result=$(curl -X POST "$KC_AUTH_URL/realms/$REALM/protocol/openid-connect/token" \
		-H 'Content-Type: application/x-www-form-urlencoded' \
		-d "grant_type=password&client_id=$CLIENT2_ID&username=$user&password=$password" \
		2> "$CURL_LOG")
	__roh-print-ok-or-failed || return $?
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
	for id in {2..9}; do __roh-create-and-login user$id password$id; done
}
