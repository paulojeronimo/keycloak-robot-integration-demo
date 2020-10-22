package com.paulojeronimo.robothelper.models;

import com.paulojeronimo.robothelper.models.credential.IvrPasswordUserCredentialModel;
import org.keycloak.models.UserCredentialModel;

public class IvrUserCredentialModel extends UserCredentialModel {
    public static final String IVR_PASSWORD = "password";
    public static final String IVR_PASSWORD_HISTORY = "ivr-passwor-history";

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
