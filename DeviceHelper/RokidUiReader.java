package io.github.ksuzukigh.rokidcontrol.device;

import android.app.UiAutomation;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.graphics.Rect;
import android.os.HandlerThread;
import android.os.Looper;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import java.util.ArrayDeque;

/** Shell-only RV101 navigation read. Never disable the user's accessibility services. */
public final class RokidUiReader {
    public static void main(String[] args) throws Exception {
        HandlerThread thread = new HandlerThread("RokidControlUiReader");
        thread.start();
        UiAutomation ui = null;
        try {
            Class<?> connectionType = Class.forName("android.app.IUiAutomationConnection");
            Object connection = Class.forName("android.app.UiAutomationConnection").getConstructor().newInstance();
            ui = UiAutomation.class.getConstructor(Looper.class, connectionType)
                .newInstance(thread.getLooper(), connection);
            UiAutomation.class.getMethod("connect", int.class).invoke(ui,
                UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
            AccessibilityServiceInfo info = ui.getServiceInfo();
            info.flags |= AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
                | AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;
            ui.setServiceInfo(info);
            String match = null;
            int matches = 0;
            for (AccessibilityWindowInfo window : ui.getWindows()) {
                if (window.getType() != AccessibilityWindowInfo.TYPE_APPLICATION) continue;
                AccessibilityNodeInfo root = window.getRoot();
                if (root == null) continue;
                if (!"com.rokid.os.sprite.launcher".contentEquals(root.getPackageName() == null ? "" : root.getPackageName())) {
                    root.recycle(); continue;
                }
                ArrayDeque<AccessibilityNodeInfo> nodes = new ArrayDeque<>(); nodes.add(root);
                int visited = 0;
                while (!nodes.isEmpty()) {
                    AccessibilityNodeInfo node = nodes.removeFirst();
                    if (visited++ >= 500) { node.recycle(); continue; }
                    if ("com.rokid.os.sprite.launcher:id/indicator".equals(node.getViewIdResourceName())
                        && node.isVisibleToUser() && node.isEnabled() && node.isClickable()) {
                        Rect r = new Rect(); node.getBoundsInScreen(r);
                        if (r.left >= 0 && r.top >= 0 && r.right <= 480 && r.bottom <= 640
                            && r.width() > 0 && r.height() > 0) {
                            matches++;
                            match = "<hierarchy><node package=\"com.rokid.os.sprite.launcher\""
                                + " resource-id=\"com.rokid.os.sprite.launcher:id/indicator\""
                                + " enabled=\"true\" clickable=\"true\" bounds=\"[" + r.left + "," + r.top
                                + "][" + r.right + "," + r.bottom + "]\"/></hierarchy>";
                        }
                    }
                    for (int i = 0; i < node.getChildCount(); i++) {
                        AccessibilityNodeInfo child = node.getChild(i);
                        if (child != null) nodes.addLast(child);
                    }
                    node.recycle();
                }
            }
            if (matches != 1) throw new IllegalStateException("No unique RV101 navigation indicator");
            System.out.println(match);
        } finally {
            if (ui != null) UiAutomation.class.getMethod("disconnect").invoke(ui);
            thread.quitSafely();
        }
    }
}
