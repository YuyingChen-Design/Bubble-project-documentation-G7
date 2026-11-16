/**
 * OscMonitor - shows every OSC message arriving on a port, so you can see
 * exactly what Wekinator sends (address, type tags, arguments) and whether
 * each address is STREAMING (continuous) or an EVENT (discrete, e.g. a DTW match).
 *
 * Needs the oscP5 library (Sketch > Import Library > Manage Libraries > oscP5).
 * Close any other sketch listening on the same port first.
 *
 * Keys:  a = toggle printing EVERY message to the console (default: events only)
 *        c = clear
 */
import oscP5.*;
import netP5.*;
import java.util.*;

final int PORT = 12000;          // Wekinator's default output port
final int QUIET_MS = 300;        // an address silent this long, then a message = "event"
final float STREAM_RATE = 5;     // >= this many msgs/s = streaming
final int LOG_LINES = 16;

OscP5 osc;
boolean printAll = false;

class AddrStats {
  String addr, typetag = "", lastArgs = "";
  int count = 0;
  int lastMs = 0;
  ArrayDeque<Integer> recent = new ArrayDeque<Integer>();
  float flash = 0;
}

final LinkedHashMap<String, AddrStats> stats = new LinkedHashMap<String, AddrStats>();
final ArrayDeque<String> eventLog = new ArrayDeque<String>();

void setup() {
  size(1000, 640);
  textFont(createFont("Monospaced", 13));
  osc = new OscP5(this, PORT);
  println("Listening for OSC on port " + PORT + "  (a = print all, c = clear)");
}

void oscEvent(OscMessage m) {
  int now = millis();
  String addr = m.addrPattern();
  String tt = m.typetag();
  Object[] a = m.arguments();
  StringBuilder sb = new StringBuilder();
  for (int i = 0; i < a.length; i++) {
    if (i > 0) sb.append(", ");
    sb.append(a[i]);
  }
  String args = a.length == 0 ? "(no args)" : sb.toString();
  String t = nf(now / 1000.0, 0, 2) + "s";

  synchronized (stats) {
    AddrStats s = stats.get(addr);
    boolean isNew = (s == null);
    if (isNew) {
      s = new AddrStats();
      s.addr = addr;
      stats.put(addr, s);
    }
    int gap = isNew ? -1 : now - s.lastMs;
    s.count++;
    s.typetag = tt;
    s.lastArgs = args;
    s.lastMs = now;
    s.recent.addLast(now);
    s.flash = 1;

    // A message after a quiet period is what a discrete event looks like.
    if (isNew || gap > QUIET_MS) {
      String line = t + "  " + addr + "  [" + tt + "]  " + args
        + (isNew ? "   <- first seen" : "   <- after " + gap + " ms quiet");
      eventLog.addFirst(line);
      while (eventLog.size() > LOG_LINES) eventLog.removeLast();
      println("EVENT  " + line);
    } else if (printAll) {
      println("       " + t + "  " + addr + "  [" + tt + "]  " + args);
    }
  }
}

void draw() {
  background(20);
  int now = millis();
  int y = 28;

  fill(255);
  text("OSC on port " + PORT + "   |   a: print all to console (" + (printAll ? "ON" : "off") + ")   c: clear", 16, y);
  y += 30;

  fill(150);
  text(String.format("%-28s %-8s %-11s %8s %8s  %s", "ADDRESS", "TYPES", "KIND", "MSG/S", "COUNT", "LAST ARGS   (age)"), 16, y);
  y += 8;
  stroke(80);
  line(16, y, width - 16, y);
  y += 20;

  synchronized (stats) {
    for (AddrStats s : stats.values()) {
      while (!s.recent.isEmpty() && now - s.recent.peekFirst() > 1000) s.recent.removeFirst();
      int rate = s.recent.size();
      String kind = rate >= STREAM_RATE ? "STREAMING" : "EVENT";

      if (s.flash > 0) {
        noStroke();
        fill(kind.equals("EVENT") ? color(200, 120, 0, 160 * s.flash) : color(0, 120, 200, 60 * s.flash));
        rect(10, y - 15, width - 20, 20);
        s.flash = max(0, s.flash - 0.04);
      }
      fill(kind.equals("EVENT") ? color(255, 190, 80) : color(140, 200, 255));
      String argsShown = s.lastArgs.length() > 40 ? s.lastArgs.substring(0, 40) + "..." : s.lastArgs;
      text(String.format("%-28s %-8s %-11s %8d %8d  %s   (%.1fs)",
        s.addr, s.typetag, kind, rate, s.count, argsShown, (now - s.lastMs) / 1000.0), 16, y);
      y += 22;
    }

    y += 20;
    fill(150);
    text("RECENT EVENTS (messages after " + QUIET_MS + " ms of silence on that address), newest first:", 16, y);
    y += 22;
    fill(255, 210, 120);
    for (String line : eventLog) {
      text(line, 16, y);
      y += 19;
    }
  }
}

void keyPressed() {
  if (key == 'a') printAll = !printAll;
  if (key == 'c') {
    synchronized (stats) {
      stats.clear();
      eventLog.clear();
    }
  }
}
