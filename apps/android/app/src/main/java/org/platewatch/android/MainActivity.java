package org.platewatch.android;

import android.app.Activity;
import android.os.Bundle;
import android.graphics.Color;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private EditText endpoint;
    private TextView status;
    private LinearLayout results;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(24, 24, 24, 24);

        TextView title = new TextView(this);
        title.setText("PlateWatch"); title.setTextSize(28); title.setTextColor(Color.rgb(45, 45, 45));
        title.setContentDescription("PlateWatch public fleet sightings");
        root.addView(title, new LinearLayout.LayoutParams(-1, -2));
        TextView subtitle = new TextView(this);
        subtitle.setText("Public fleet sightings · read-only"); subtitle.setTextSize(15);
        root.addView(subtitle, new LinearLayout.LayoutParams(-1, -2));

        endpoint = new EditText(this);
        endpoint.setSingleLine(true); endpoint.setText("http://10.0.2.2:8083");
        endpoint.setHint("REST mirror URL (HTTPS in production)");
        endpoint.setInputType(33);
        root.addView(endpoint, new LinearLayout.LayoutParams(-1, -2));
        Button refresh = new Button(this); refresh.setText("Refresh sightings");
        refresh.setOnClickListener(v -> load());
        root.addView(refresh, new LinearLayout.LayoutParams(-1, -2));
        status = new TextView(this); status.setText("Connect to the PlateWatch mirror to begin.");
        status.setPadding(0, 12, 0, 12); root.addView(status, new LinearLayout.LayoutParams(-1, -2));

        results = new LinearLayout(this); results.setOrientation(LinearLayout.VERTICAL); results.setPadding(0, 4, 0, 24);
        ScrollView scroll = new ScrollView(this); scroll.addView(results);
        root.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));
        setContentView(root);
    }

    private void load() {
        status.setText("Loading…"); results.removeAllViews();
        String base = endpoint.getText().toString();
        executor.execute(() -> {
            try {
                PlateWatchApi.Page page = PlateWatchApi.fetch(base);
                runOnUiThread(() -> render(page));
            } catch (Exception error) {
                runOnUiThread(() -> status.setText("Could not connect: " + error.getMessage()));
            }
        });
    }

    private void render(PlateWatchApi.Page page) {
        status.setText(page.items().size() + " public fleet sightings");
        if (page.items().isEmpty()) {
            TextView empty = new TextView(this); empty.setText("No published fleet sightings yet.");
            empty.setGravity(Gravity.CENTER_HORIZONTAL); results.addView(empty); return;
        }
        for (PlateWatchApi.Sighting item : page.items()) {
            TextView row = new TextView(this);
            String agency = item.agencyName() == null ? "Fleet vehicle" : item.agencyName();
            String unit = item.unitNumber() == null ? "unit not published" : "unit " + item.unitNumber();
            row.setText(agency + " · " + unit + "\n" + item.capturedAt() +
                    " · fleet confidence " + String.format("%.0f%%", item.fleetConfidence() * 100));
            row.setTextSize(16); row.setPadding(12, 14, 12, 14);
            row.setBackgroundColor(Color.rgb(247, 244, 238)); row.setContentDescription(row.getText());
            results.addView(row, new LinearLayout.LayoutParams(-1, -2));
        }
    }

    @Override protected void onDestroy() { executor.shutdownNow(); super.onDestroy(); }
}
