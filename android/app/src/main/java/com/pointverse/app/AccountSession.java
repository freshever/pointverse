package com.pointverse.app;

import android.content.*;
import android.security.keystore.*;
import android.util.Base64;
import org.json.JSONObject;
import java.security.KeyStore;
import java.time.Instant;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;

/** Android Keystore protects the same bearer session used by iOS. Passwords are never persisted. */
final class AccountSession {
    private final SharedPreferences preferences;
    private static final String ALIAS="pointverse.account.v1";
    private String token="", name="", id="";
    private Instant expiry=Instant.EPOCH;
    AccountSession(Context context) {
        preferences=context.getSharedPreferences("account-session",Context.MODE_PRIVATE);
        try {
            String saved=preferences.getString("session",null);
            if(saved!=null) {
                JSONObject envelope=new JSONObject(saved);
                Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
                cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,Base64.decode(envelope.getString("iv"),Base64.NO_WRAP)));
                decode(new JSONObject(new String(cipher.doFinal(Base64.decode(envelope.getString("data"),Base64.NO_WRAP)),java.nio.charset.StandardCharsets.UTF_8)));
            }
        } catch(Exception ignored) { clear(); }
    }
    private javax.crypto.SecretKey key() throws Exception {
        KeyStore store=KeyStore.getInstance("AndroidKeyStore"); store.load(null);
        if(store.containsAlias(ALIAS)) return (javax.crypto.SecretKey)store.getKey(ALIAS,null);
        KeyGenerator generator=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }
    private void decode(JSONObject session) throws Exception {
        if(!"Bearer".equals(session.getString("token_type"))) throw new IllegalArgumentException();
        String value=session.getString("access_token"); Instant until=Instant.parse(session.getString("expires_at"));
        if(value.isEmpty() || !until.isAfter(Instant.now())) throw new IllegalArgumentException();
        token=value; expiry=until; id=session.getJSONObject("user").optString("id",""); name=session.getJSONObject("user").optString("display_name","点界用户");
    }
    synchronized void save(JSONObject session) throws Exception {
        // Encrypt and commit before exposing a successful login.
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE,key());
        byte[] encrypted=cipher.doFinal(session.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
        JSONObject envelope=new JSONObject().put("iv",Base64.encodeToString(cipher.getIV(),Base64.NO_WRAP)).put("data",Base64.encodeToString(encrypted,Base64.NO_WRAP));
        if(!preferences.edit().putString("session",envelope.toString()).commit()) throw new java.io.IOException("无法保存登录信息");
        decode(session);
    }
    synchronized String token() { return expiry.isAfter(Instant.now())?token:""; }
    synchronized String id() { return id; }
    synchronized String name() { return name; }
    synchronized void clear() { token=""; name=""; id=""; expiry=Instant.EPOCH; preferences.edit().remove("session").commit(); }
}
