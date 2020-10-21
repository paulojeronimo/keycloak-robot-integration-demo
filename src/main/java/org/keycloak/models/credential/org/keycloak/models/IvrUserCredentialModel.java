package org.keycloak.models.credential.org.keycloak.models;

import org.keycloak.models.UserCredentialModel;
import org.keycloak.models.credential.IvrPasswordUserCredentialModel;

public class IvrUserCredentialModel extends UserCredentialModel {
    public static final String IVR_PASSWORD = "password";
    public static IvrPasswordUserCredentialModel password(String password) {
        return password(password, false);
    }
    public static IvrPasswordUserCredentialModel password(String password, boolean adminRequest) {
        IvrPasswordUserCredentialModel model = new IvrPasswordUserCredentialModel();
        model.setType(IVR_PASSWORD);
        model.setValue(password);
        model.setAdminRequest(adminRequest);
        return model;
    }
}
