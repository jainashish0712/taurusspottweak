#include <stdio.h>
#include <string.h>
#include "miniz.h"

int main() {
    mz_zip_archive zip;
    memset(&zip, 0, sizeof(zip));
    if (!mz_zip_reader_init_file(&zip, "scratch/Spleeter4Model.mlmodelc.zip", 0)) {
        printf("Failed to open zip\n");
        return 1;
    }
    mz_uint count = mz_zip_reader_get_num_files(&zip);
    printf("Total files in zip: %u\n", count);
    for (mz_uint i = 0; i < count; i++) {
        mz_zip_archive_file_stat s;
        if (mz_zip_reader_file_stat(&zip, i, &s)) {
            printf("  %s (%llu bytes)\n", s.m_filename, (unsigned long long)s.m_uncomp_size);
        }
    }
    mz_zip_reader_end(&zip);
    return 0;
}
