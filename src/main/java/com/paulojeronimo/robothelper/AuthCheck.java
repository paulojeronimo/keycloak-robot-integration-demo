package com.paulojeronimo.robothelper;

import org.jboss.logging.Logger;
import org.keycloak.models.ClientModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RoleModel;
import org.keycloak.representations.AccessToken;
import org.keycloak.services.managers.AppAuthManager;
import org.keycloak.services.managers.Auth;
import org.keycloak.services.managers.AuthenticationManager;

import javax.ws.rs.ForbiddenException;
import javax.ws.rs.NotAuthorizedException;
import java.util.stream.Collectors;

public class AuthCheck {
    private static final Logger log = Logger.getLogger(AuthCheck.class);

    public static AuthenticationManager.AuthResult whoAmI(KeycloakSession session) {
        final AuthenticationManager.AuthResult authResult = abortIfNotAuthenticated(session);
        if (authResult == null) {
            log.infof("Anonymous user entering realm %s", session.getContext().getRealm().getName());
        } else {
            ClientModel client = session.getContext().getRealm().getClientByClientId(authResult.getToken().getIssuedFor());
            log.infof("%s, realm: %s, client: %s", authResult.getUser().getUsername(), session.getContext().getRealm().getName(), client.getClientId());
            log.infof("Realm roles: %s", authResult.getUser().getRealmRoleMappings().stream().map(RoleModel::getName).collect(Collectors.toSet()));
        }
        return authResult;
    }

    public static void hasRole(AuthenticationManager.AuthResult authResult, String role) {
        if (authResult.getToken().getRealmAccess() == null || !authResult.getToken().getRealmAccess().isUserInRole(role)) {
            throw new ForbiddenException("You do not have the required credentials for this action");
        }
    }

    public static void hasManageUsersRole(AuthenticationManager.AuthResult authResult) {
        AccessToken.Access access = authResult.getToken().getResourceAccess("realm-management");
        if (access != null && access.isUserInRole("manage-users"))
            return;
        throw new ForbiddenException("You do not have the required credentials for this action");
    }

   public static AuthenticationManager.AuthResult abortIfNotAuthenticated(KeycloakSession session) {
        final AuthenticationManager.AuthResult authResult = new AppAuthManager().authenticateBearerToken(session);
        abortIfNotAuthenticated(authResult);
        return authResult;
    }

    public static void abortIfNotAuthenticated(AuthenticationManager.AuthResult authResult) {
        if (authResult == null) {
            throw new NotAuthorizedException("Bearer token required");
        }
    }
}