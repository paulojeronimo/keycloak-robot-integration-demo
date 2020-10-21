package com.paulojeronimo.robothelper;

import org.jboss.logging.Logger;
import org.keycloak.models.*;
import org.keycloak.services.managers.AuthenticationManager;
import org.keycloak.services.resource.RealmResourceProvider;

import javax.ws.rs.*;
import javax.ws.rs.core.MediaType;
import javax.ws.rs.core.Response;
import java.util.List;


public class IvrResourceProvider<s> implements RealmResourceProvider {
    public class IvrResponse {
        private String message;
        public IvrResponse(String message) {
            this.message = message;
        }
        public String getMessage() {
            return message;
        }
    }

    private static final Logger log = Logger.getLogger(IvrResourceProvider.class);
    private final KeycloakSession session;

    public IvrResourceProvider(KeycloakSession session) {
        this.session = session;
    }

    @POST
    @Path("create-user")
    @Produces({MediaType.APPLICATION_JSON})
    @Consumes({MediaType.APPLICATION_FORM_URLENCODED})
    public Response createUser(
            @FormParam("username") String username,
            @FormParam("password") String password) {
        AuthenticationManager.AuthResult authResult = AuthCheck.whoAmI(session);
        AuthCheck.hasManageUsersRole(authResult);
        log.infof("User %s calling createUser", authResult.getUser().getUsername());
        final UserProvider userProvider = session.userStorageManager();
        final RealmModel realm = session.getContext().getRealm();
        final UserCredentialManager userCredentialManager = session.userCredentialManager();
        final List<UserModel> users = userProvider.searchForUser(username, realm);
        String message;
        if (users.size() > 0) {
            message = "User " + username + " already exists!";
            log.info(message);
            return Response.status(Response.Status.NOT_ACCEPTABLE).entity(new IvrResponse(message)).build();
        }
        UserModel user = userProvider.addUser(realm, username);
        user.setEnabled(true);
        userCredentialManager.updateCredential(realm, user, UserCredentialModel.password(password));
        message = "User " + username + " created!";
        return Response.status(Response.Status.OK).entity(new IvrResponse(message)).build();
    }

    @Override
    public Object getResource() {
        return this;
    }

    @Override
    public void close() {
    }
}