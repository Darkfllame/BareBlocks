import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.List;
import java.util.TreeSet;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import java.util.stream.Stream;

/// Dumps data that isn't in the data generator's reports, read by build/gen_data.zig:
/// - `<properties_out>`: every property of BlockStateProperties as `<FIELD_NAME> <name> <value>,<value>,...` lines
/// - `<registries_out>`: `known_pack <namespace> <id> <version>`, then a `registry <id> <entry>,<entry>,...` line
///   per synchronized registry, in the order the vanilla server sends them
///
/// Usage: java DumpVanilla.java <server.jar> <properties_out> <registries_out>
public class DumpVanilla {
    public static void main(String[] args) throws Exception {
        Path tmp = Files.createTempDirectory("bare_blocks_properties");
        try {
            List<URL> urls = new ArrayList<>();
            Path serverJar = null;
            // The server jar is a bundler, the actual server and its libraries are inside of it
            try (JarFile bundler = new JarFile(args[0])) {
                for (String kind : new String[] { "versions", "libraries" }) {
                    var list = bundler.getInputStream(bundler.getJarEntry("META-INF/" + kind + ".list"));
                    try (BufferedReader reader = new BufferedReader(new InputStreamReader(list))) {
                        String line;
                        while ((line = reader.readLine()) != null) {
                            if (line.isBlank()) continue;
                            // <sha256>\t<id>\t<path>
                            String path = line.split("\t")[2];
                            Path out = tmp.resolve(kind).resolve(path);
                            Files.createDirectories(out.getParent());
                            try (InputStream in = bundler.getInputStream(bundler.getJarEntry("META-INF/" + kind + "/" + path))) {
                                Files.copy(in, out);
                            }
                            urls.add(out.toUri().toURL());
                            if (kind.equals("versions")) serverJar = out;
                        }
                    }
                }
            }

            try (URLClassLoader loader = new URLClassLoader(urls.toArray(new URL[0]))) {
                Thread.currentThread().setContextClassLoader(loader);
                // Some properties' values (NoteBlockInstrument...) need the registries
                loader.loadClass("net.minecraft.SharedConstants").getMethod("tryDetectVersion").invoke(null);
                loader.loadClass("net.minecraft.server.Bootstrap").getMethod("bootStrap").invoke(null);

                Class<?> holder = loader.loadClass("net.minecraft.world.level.block.state.properties.BlockStateProperties");
                Class<?> property = loader.loadClass("net.minecraft.world.level.block.state.properties.Property");
                Method getName = property.getMethod("getName");
                Method getValues = property.getMethod("getPossibleValues");
                Method valueName = property.getMethod("getName", Comparable.class);

                try (PrintWriter out = new PrintWriter(Files.newBufferedWriter(Path.of(args[1])))) {
                    for (Field field : holder.getFields()) {
                        if (!Modifier.isStatic(field.getModifiers()) || !property.isAssignableFrom(field.getType())) continue;
                        Object prop = field.get(null);

                        List<String> values = new ArrayList<>();
                        for (Object value : (Collection<?>) getValues.invoke(prop)) {
                            values.add((String) valueName.invoke(prop, value));
                        }
                        out.println(field.getName() + " " + getName.invoke(prop) + " " + String.join(",", values));
                    }
                }

                try (PrintWriter out = new PrintWriter(Files.newBufferedWriter(Path.of(args[2])));
                     JarFile server = new JarFile(serverJar.toFile())) {
                    Object version = loader.loadClass("net.minecraft.SharedConstants").getMethod("getCurrentVersion").invoke(null);
                    out.println("known_pack minecraft core " + version.getClass().getMethod("id").invoke(version));

                    Class<?> dataLoader = loader.loadClass("net.minecraft.resources.RegistryDataLoader");
                    Class<?> registryData = loader.loadClass("net.minecraft.resources.RegistryDataLoader$RegistryData");
                    Method key = registryData.getMethod("key");
                    Method identifier = loader.loadClass("net.minecraft.resources.ResourceKey").getMethod("identifier");
                    Method getPath = loader.loadClass("net.minecraft.resources.Identifier").getMethod("getPath");

                    for (Object data : (List<?>) dataLoader.getField("SYNCHRONIZED_REGISTRIES").get(null)) {
                        Object id = identifier.invoke(key.invoke(data));
                        // Same as Registries.elementsDirPath, vanilla only has the minecraft namespace
                        String dir = "data/minecraft/" + getPath.invoke(id) + "/";

                        // Vanilla lists them through a TreeMap of the files' identifiers
                        TreeSet<String> files = new TreeSet<>();
                        for (JarEntry entry : (Iterable<JarEntry>) server.stream()::iterator) {
                            String name = entry.getName();
                            if (name.startsWith(dir) && name.endsWith(".json")) files.add(name.substring(dir.length()));
                        }
                        List<String> entries = new ArrayList<>();
                        for (String file : files) entries.add("minecraft:" + file.substring(0, file.length() - ".json".length()));
                        out.println("registry " + id + " " + String.join(",", entries));
                    }
                }
            }
        } finally {
            try (Stream<Path> walk = Files.walk(tmp)) {
                walk.sorted(Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
            }
        }
        // Bootstrap leaves non-daemon threads behind
        System.exit(0);
    }
}
