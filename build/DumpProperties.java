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
import java.util.jar.JarFile;
import java.util.stream.Stream;

/// Dumps every property of BlockStateProperties as `<FIELD_NAME> <name> <value>,<value>,...` lines,
/// read by build/gen_data.zig to name the block state properties like mojang does.
///
/// Usage: java DumpProperties.java <server.jar> <output>
public class DumpProperties {
    public static void main(String[] args) throws Exception {
        Path tmp = Files.createTempDirectory("bare_blocks_properties");
        try {
            List<URL> urls = new ArrayList<>();
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
