// Okular document-open harness: the fuzz input becomes a document of one format and is opened and
// rendered through Okular::Document, which loads the matching generator plugin. One source, built once
// per format with -DFORMAT_SUFFIX/-DFORMAT_MIME (see build.sh).
#include <KPluginMetaData>
#include <QApplication>
#include <QDir>
#include <QMimeDatabase>
#include <QUrl>

#include <algorithm>
#include <cstdlib>
#include <unistd.h>

#include "core/document.h"
#include "core/generator.h"
#include "core/observer.h"
#include "core/page.h"
#include "settings_core.h"

#ifndef FORMAT_SUFFIX
#error "define FORMAT_SUFFIX (e.g. \".g3\")"
#endif
#ifndef FORMAT_MIME
#error "define FORMAT_MIME (e.g. \"image/fax-g3\")"
#endif
#ifndef OKULAR_GENERATOR
#error "define OKULAR_GENERATOR (plugin id of the generator for FORMAT_MIME)"
#endif
#ifndef OKULAR_PLUGIN_PREFIX
#error "define OKULAR_PLUGIN_PREFIX (directory that contains okular_generators/)"
#endif

namespace
{
QString g_scratch;
QString g_docdata;
unsigned long g_counter;

class NullObserver : public Okular::DocumentObserver
{
};
}

extern "C" int LLVMFuzzerInitialize(int *, char ***)
{
    const char *tmp = getenv("TMPDIR");
    QByteArray tmpl = QByteArray(tmp && *tmp ? tmp : "/tmp") + "/okular-fuzz-XXXXXX";
    if (!mkdtemp(tmpl.data())) {
        return 1;
    }
    g_scratch = QString::fromLocal8Bit(tmpl);
    qputenv("XDG_DATA_HOME", QByteArray(tmpl + "/data").constData());
    qputenv("XDG_CONFIG_HOME", QByteArray(tmpl + "/config").constData());
    qputenv("XDG_CACHE_HOME", QByteArray(tmpl + "/cache").constData());
    qputenv("HOME", tmpl.constData());
    qputenv("QT_QPA_PLATFORM", "offscreen");
    qputenv("LC_ALL", "C.UTF-8");
    g_docdata = g_scratch + QStringLiteral("/data/okular/docdata");

    static int argc = 1;
    static char arg0[] = "fuzz_okular";
    static char *argv[] = {arg0, nullptr};
    new QApplication(argc, argv);
    Okular::SettingsCore::instance(QStringLiteral("okular-fuzz"));
    QCoreApplication::addLibraryPath(QStringLiteral(OKULAR_PLUGIN_PREFIX));
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    const QString path = g_scratch + QStringLiteral("/in%1").arg(g_counter++) + QStringLiteral(FORMAT_SUFFIX);
    {
        QFile f(path);
        if (!f.open(QIODevice::WriteOnly) || f.write(reinterpret_cast<const char *>(data), qint64(size)) != qint64(size)) {
            abort();
        }
    }

    int ret = -1;
    {
        Okular::Document doc(nullptr);
        NullObserver observer;
        doc.addObserver(&observer);
        const QMimeType mime = QMimeDatabase().mimeTypeForName(QStringLiteral(FORMAT_MIME));
        // Okular falls back to a generator picked from the file content when the one for FORMAT_MIME
        // refuses the input; only inputs the intended generator accepted are kept.
        if (doc.openDocument(path, QUrl::fromLocalFile(path), mime) == Okular::Document::OpenSuccess && doc.generatorInfo().pluginId() == QStringLiteral(OKULAR_GENERATOR)) {
            ret = 0;
            const uint pages = std::min<uint>(doc.pages(), 3);
            for (uint i = 0; i < pages; ++i) {
                const Okular::Page *page = doc.page(i);
                const int w = 400;
                const double hd = page->ratio() * w;
                const int h = hd >= 4096 ? 4096 : (hd >= 1 ? int(hd) : 1);
                doc.requestPixmaps({new Okular::PixmapRequest(&observer, int(i), w, h, 1.0, 1, Okular::PixmapRequest::NoFeature)});
                doc.requestTextPage(i);
            }
        }
        doc.closeDocument();
        doc.removeObserver(&observer);
    }

    QFile::remove(path);
    QDir(g_docdata).removeRecursively();
    return ret;
}
