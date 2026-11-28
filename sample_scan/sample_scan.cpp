#include <adtf_file/standard_adtf_file_reader.h>
#include <iostream>

int main(int argc, char* argv[])
{
    if (argc != 2) {
        std::cerr << "Expected one ADTF recording path.\n";
        return 1;
    }

    uint64_t items = 0;
    uint64_t samples = 0;
    try {
        adtf_file::Objects objects;
        adtf_file::PluginInitializer initializer([] { adtf_file::add_standard_objects(); });
        adtf_file::ADTFDatFileReader reader;
        reader.open(argv[1]);
        const auto expected = reader.getItemCount();
        try {
            while (true) {
                const auto item = reader.getNextItem();
                ++items;
                if (dynamic_cast<const adtf_file::Sample*>(item.stream_item.get())) {
                    ++samples;
                }
            }
        } catch (const adtf_file::exceptions::EndOfFile&) {
            if (!expected || items != *expected) {
                std::cerr << "Unexpected end of recording after " << items << " items.\n";
                return 1;
            }
        }
        if (samples == 0) {
            std::cout << "WARNING: No samples to check.\n";
            return 3;
        }
        std::cout << "OK: Sample readability scan passed. Read " << samples << " samples ("
                  << items << " stream items).\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Read failed after " << items << " stream items: " << error.what() << '\n';
        return 1;
    }
}