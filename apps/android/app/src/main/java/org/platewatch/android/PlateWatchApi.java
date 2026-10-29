package org.platewatch.android;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/** Read-only client for the shared PlateWatch REST public DTO. */
final class PlateWatchApi {
    record Sighting(String id, String capturedAt, String unitNumber,
                    String agencyName, double fleetConfidence) {}
    record Page(List<Sighting> items, String nextCursor) {}

    static Page fetch(String baseUrl) throws Exception {
        String normalized = baseUrl.trim().replaceAll("/+$", "");
        URL url = URI.create(normalized + "/v1/sightings?limit=50").toURL();
        HttpURLConnection connection = (HttpURLConnection) url.openConnection();
        connection.setRequestMethod("GET");
        connection.setConnectTimeout(8000);
        connection.setReadTimeout(12000);
        connection.setRequestProperty("Accept", "application/json");
        int code = connection.getResponseCode();
        if (code < 200 || code >= 300) throw new IOException("server returned HTTP " + code);
        StringBuilder body = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                connection.getInputStream(), StandardCharsets.UTF_8))) {
            for (String line; (line = reader.readLine()) != null;) body.append(line);
        } finally { connection.disconnect(); }
        return parsePage(new JSONObject(body.toString()));
    }

    static Page parsePage(JSONObject root) {
        JSONArray array = root.optJSONArray("items");
        List<Sighting> result = new ArrayList<>();
        if (array != null) for (int i = 0; i < array.length(); i++) {
            JSONObject item = array.optJSONObject(i);
            if (item == null) continue;
            result.add(new Sighting(item.optString("id", ""),
                    item.optString("capturedAt", ""),
                    item.isNull("unitNumber") ? null : item.optString("unitNumber"),
                    item.isNull("agencyName") ? null : item.optString("agencyName"),
                    item.optDouble("fleetConfidence", 0.0)));
        }
        return new Page(result, root.isNull("nextCursor") ? null : root.optString("nextCursor"));
    }
}
