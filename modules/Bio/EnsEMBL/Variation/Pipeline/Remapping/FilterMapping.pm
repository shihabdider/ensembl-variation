#!/usr/bin/env perl
# Copyright [1999-2014] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.




=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

  Questions may also be sent to the Ensembl help desk at
  <helpdesk.org>.

=cut
package Bio::EnsEMBL::Variation::Pipeline::Remapping::FilterMapping;

use strict;
use warnings;

use FileHandle;
use Bio::DB::Fasta;
use Bio::EnsEMBL::Registry;

use base ('Bio::EnsEMBL::Hive::Process');

sub fetch_input {
    my $self = shift;
    my $file_number           = $self->param('file_number');
    my $mapping_results_dir   = $self->param('mapping_results_dir');
    my $filtered_mappings_dir = $self->param('filtered_mappings_dir');
    my $statistics_dir        = $self->param('statistics_dir');
    my $dump_features_dir     = $self->param('dump_features_dir');
    my $load_features_dir     = $self->param('load_features_dir');
    my $fasta_files_dir       = $self->param('fasta_files_dir');

    my $file_mappings          = "$mapping_results_dir/mappings_$file_number.txt";
    my $file_failed_mappings   = "$mapping_results_dir/failed_mapping_$file_number.txt";
    my $file_init_feature      = "$dump_features_dir/$file_number.txt";
    my $file_filtered_mappings = "$filtered_mappings_dir/$file_number.txt";
    my $file_statistics        = "$statistics_dir/$file_number.txt";    
    my $file_load_features     = "$load_features_dir/$file_number.txt";
    my $fasta_file             = "$fasta_files_dir/$file_number.fa";

    $self->param('file_mappings', $file_mappings);
    $self->param('file_failed_mappings', $file_failed_mappings);
    $self->param('file_init_feature', $file_init_feature);
    $self->param('file_filtered_mappings', $file_filtered_mappings);
    $self->param('file_statistics', $file_statistics);
    $self->param('file_load_features', $file_load_features);
    $self->param('fasta_file', $fasta_file);

    # get seq_region ids for new assembly
    my $registry = 'Bio::EnsEMBL::Registry';
    $registry->load_all($self->param('registry_file_newasm'));
    my $cdba = $registry->get_DBAdaptor($self->param('species'), 'core');
    $self->param('cdba', $cdba);

}

sub run {
    my $self = shift;
    $self->report_failed_mappings();
    if ($self->param('mode') eq 'remap_multi_map') {
        $self->filter_mapping_results_dbsnp();
    } else {
        $self->filter_mapping_results();
    }
    $self->write_statistics();
    $self->join_feature_data();
}

sub write_output {
    my $self = shift;

}

sub report_failed_mappings {
    my $self = shift;
    my $file_mappings = $self->param('file_mappings');
    my $file_failed_mappings = $self->param('file_failed_mappings');

    my $mapped = {};
    my $unmapped = {};
    my $fh_mappings = FileHandle->new($file_mappings, 'r');
    while (<$fh_mappings>) {
        chomp;
        my ($old_seq_info, $new_seq_info, $query_name, $map_weight, $cigar, $relative_algn_score, $clipped_info) = split("\t", $_);
        $mapped->{$query_name} = 1;
    }
    $fh_mappings->close();

    my $fh_failed_mappings = FileHandle->new($file_failed_mappings, 'r');
    while (<$fh_failed_mappings>) {
        chomp;
        my ($indel, $old_seq_info, $new_seq_info, $query_name, $map_weight, $cigar, $relative_algn_score, $clipped_info) = split("\t", $_);
        unless ($mapped->{$query_name}) {
            $unmapped->{$query_name} = 1;
        }
    }
    $fh_failed_mappings->close();

    my $count_mapped = scalar keys %$mapped;
    my $count_unmapped = scalar keys %$unmapped;

    $self->param('pre_count_mapped', $count_mapped);
    $self->param('pre_count_unmapped', $count_unmapped);

    # get input id counts
    my $count_input_ids = 0;
    my $fasta_file = $self->param('fasta_file');
    my $fh_fasta_file = FileHandle->new($fasta_file, 'r');
    while (<$fh_fasta_file>) {
        chomp;
        if (/^>/) {
            $count_input_ids++;
        }
    }
    $fh_fasta_file->close();
    $self->param('count_input_ids', $count_input_ids);

}

sub filter_mapping_results {
    my $self = shift;

    my $algn_score_threshold = $self->param('algn_score_threshold');
    my $use_prior_info = $self->param('use_prior_for_filtering');

    my $file_mappings = $self->param('file_mappings');
    my $fh_mappings = FileHandle->new($file_mappings, 'r');

    my $file_filtered_mappings = $self->param('file_filtered_mappings');
    my $fh_filtered_mappings = FileHandle->new($file_filtered_mappings, 'w');

    my $multi_map_all = {};
    my $multi_map_same_chrom = {};

    my ($stats_failed, $stats_unique_map, $stats_multi_map);

    while (<$fh_mappings>) {
        chomp;
        my ($old_seq_info, $new_seq_info, $query_name, $map_weight, $cigar, $relative_algn_score, $clipped_info) = split("\t", $_);
        #query_name: 156358-150-1-150-11:5502587:5502587:1:T/C:rs202026261:dbSNP:SNV
        #filter old chrom name
    
        my $old_chrom_name;    
        if ($use_prior_info) {
            my @query_name_components_fst_part = split('-', $query_name, 5);
            my @query_name_components_snd_part = split(':', $query_name_components_fst_part[4], 2);
            $old_chrom_name = $query_name_components_snd_part[0];
        }

        my ($chrom_name, $start, $end, $strand) = split(' ', $new_seq_info);
        if ($map_weight > 1) {
            $multi_map_all->{$query_name}->{$new_seq_info} = $relative_algn_score;
            if ($use_prior_info) {
                if ($chrom_name eq $old_chrom_name) {
                    $multi_map_same_chrom->{$query_name}->{$new_seq_info} = $relative_algn_score;
                } 
            }
        } else {
            if ($relative_algn_score >= $algn_score_threshold) {
                my $line = $self->print_feature_line($query_name, $new_seq_info, $relative_algn_score);
                print $fh_filtered_mappings $line, "\n";
                $stats_unique_map++;
            } else {
                $stats_failed++;
            }
        }
    }
    $fh_mappings->close();

    my $count_multi_map_all        = scalar keys %$multi_map_all;
    my $count_multi_map_same_chrom = scalar keys %$multi_map_same_chrom;

    my $diff = $count_multi_map_all - $count_multi_map_same_chrom;
    $stats_failed += $diff;

    my $multi_map_working = {};
    if ($use_prior_info) {
        $multi_map_working = $multi_map_same_chrom;
    } else {
        $multi_map_working = $multi_map_all;
    }

    my $filtered_multi_map = {};
    foreach my $query_name (keys %$multi_map_working) {
        my $mappings = $multi_map_working->{$query_name};  
        my $count_before = scalar keys %$mappings;
        if ($count_before == 0) {
            next; # warn? only maps to non_chrom
        }
        my $count_after = 0;

        my @new_seq_infos = sort { $mappings->{$b} <=> $mappings->{$a} } keys(%$mappings);

        # check that the first one has score 1, then only select those with score 1
        # if the first has not score of one then select based on threshold
        my $threshold = $algn_score_threshold;
        if ($mappings->{$new_seq_infos[0]} == 1.0) {
            $threshold = 1.0;
        }
        foreach my $new_seq_info (@new_seq_infos) {
            my $score = $mappings->{$new_seq_info};
            if ($score >= $threshold) {
                my $line = $self->print_feature_line($query_name, $new_seq_info, $score);
                $filtered_multi_map->{$query_name}->{$line} = 1;
                $count_after++;
            }
        }
        if ($count_after == 0) {
            $stats_failed++;
        }
    }

    foreach my $query_name (keys %$filtered_multi_map) {
        my $mappings = $filtered_multi_map->{$query_name};
        my $count = scalar keys %$mappings;
        if ($count == 1) {
            $stats_unique_map++;
        } else {
            $stats_multi_map++;
        }
        foreach my $line (keys %$mappings) {
            print $fh_filtered_mappings $line, "\n";
        }

    }
    $self->param('stats_unique_map', $stats_unique_map);
    $self->param('stats_multi_map', $stats_multi_map);
    $self->param('stats_failed', $stats_failed);

    $fh_filtered_mappings->close();

}

sub filter_mapping_results_dbsnp {
    my $self = shift;
    my $algn_score_threshold = $self->param('algn_score_threshold');

    my $file_mappings = $self->param('file_mappings');
    my $fh_mappings = FileHandle->new($file_mappings, 'r');

    my $file_filtered_mappings = $self->param('file_filtered_mappings');
    my $fh_filtered_mappings = FileHandle->new($file_filtered_mappings, 'w');

    my ($stats_failed, $stats_unique_map, $stats_multi_map);

    my $mapped = {};
    while (<$fh_mappings>) {
        chomp;
        # old_seq_info is not in available
        #       1 19432 19432 1 480394.0-101-1-101-A/G:rs75513536       8       203M    1                       clipped nucleotides 0
        #       1 19432 19432 1 480394.1-101-1-101-A/G:rs75513536       8       203M    0.995073891625616       clipped nucleotides 0

        #        1 18849 18849 -1        14086.1-110-1-497-G:C/G:rs708635        3       41S567M 0.932565789473684       clipped nucleotides 41
        #        1 19172 19172 -1        14567.1-200-1-200-T:C/T:rs806720        8       110M2I289M      0.992518703241895       clipped nucleotides 0
        #        1 19241 19241 -1        4257.1-257-1-250-G:A/G:rs380444 3       508M    0.998031496062992       clipped nucleotides 0
        my ($old_seq_info, $new_seq_info, $query_name, $map_weight, $cigar, $relative_algn_score, $clipped_info) = split("\t", $_);

        my ($chrom_name, $start, $end, $strand) = split(' ', $new_seq_info);
        my @query_name_components = split('-', $query_name, 5);
        my $vf_id_info = $query_name_components[0];
        my ($vf_id, $version) = split('\.', $vf_id_info);
        my ($allele, $allele_string, $rsid) = split(':', $query_name_components[4]);
        $mapped->{$vf_id}->{$new_seq_info}->{$query_name} = $relative_algn_score;
    }
    $fh_mappings->close();

    #content of $mapped could look like this:
    #3509 22 18401349 18401376 -1 3509.1-200-28-200--/CGGAGCCAGAGGGCCGGGGGGTCCCACA:rs361903 0.992990654205608
    #3509 22 18718507 18718506 1 3509.0-200-0-200--/CGGAGCCAGAGGGCCGGGGGGTCCCACA:rs361903 1
    #3509 22 18223193 18223220 1 3509.1-200-28-200--/CGGAGCCAGAGGGCCGGGGGGTCCCACA:rs361903 0.992990654205608
    #3509 22 21344289 21344316 1 3509.1-200-28-200--/CGGAGCCAGAGGGCCGGGGGGTCCCACA:rs361903 0.995327102803738
    #3509 22 18650965 18650992 -1 3509.1-200-28-200--/CGGAGCCAGAGGGCCGGGGGGTCCCACA:rs361903 0.995327102803738

    #27587 9 65226786 65226786 -1 27587.1-140-1-507-C/G:rs1838599 0.998456790123457
    #27587 9 65226786 65226786 -1 27587.0-140-1-507-C/G:rs1838599 1

    #27587 9 63022076 63022076 1 27587.1-140-1-507-C/G:rs1838599 0.970679012345679
    #27587 9 63022076 63022076 1 27587.0-140-1-507-C/G:rs1838599 0.972222222222222

    #27587 9 65795203 65795203 1 27587.1-140-1-507-C/G:rs1838599 0.976851851851852
    #27587 9 65795203 65795203 1 27587.0-140-1-507-C/G:rs1838599 0.978395061728395

    #27587 9 64741286 64741286 -1 27587.1-140-1-507-C/G:rs1838599 0.983024691358025
    #27587 9 64741286 64741286 -1 27587.0-140-1-507-C/G:rs1838599 0.984567901234568

    # if coords are the same, choose the one with better score --> consider allele string?


    foreach my $vf_id (keys %$mapped) {
        my $passed = {};

        foreach my $new_seq_info (keys %{$mapped->{$vf_id}}) {
            # query_name to score
            my $query_name_to_score = $mapped->{$vf_id}->{$new_seq_info};
            my @scores = sort { $query_name_to_score->{$b} <=> $query_name_to_score->{$a} } keys(%$query_name_to_score);
            my $query_name = $scores[0];
            my $score = $query_name_to_score->{$query_name};

            if ($score >= $algn_score_threshold) {
                $passed->{"$vf_id\t$new_seq_info\t$query_name"} = $score;
            }
        }

        my $count_passed = scalar keys %$passed;
        if ($count_passed > 0) {
            # filter by score
            my $filtered = {};
            my @keys = sort {$passed->{$b} <=> $passed->{$a}} keys(%$passed);
            my $threshold = $algn_score_threshold;
            if ($passed->{$keys[0]} == 1.0) {
                $threshold = 1.0;
            }
            foreach my $result (keys %$passed) {
                my $score = $passed->{$result};
                if ($score >= $threshold) {
                    $filtered->{$result} = $score;
                    my ($vf_id, $new_seq_info, $query_name) = split("\t", $result);
                    my $line = $self->print_feature_line($query_name, $new_seq_info, $score);
                    print $fh_filtered_mappings $line, "\n";
                }   
            }

            $count_passed = scalar keys %$filtered;
            if ($count_passed == 0) {
                $stats_failed++;
            } elsif ($count_passed == 1) {
                $stats_unique_map++;
            } else {
                $stats_multi_map++;
            }
        } else {
            $stats_failed++;
        }
    }

    $fh_filtered_mappings->close();

    $self->param('stats_unique_map', $stats_unique_map);
    $self->param('stats_multi_map', $stats_multi_map);
    $self->param('stats_failed', $stats_failed);
}

sub write_statistics {
    my $self = shift;
    my $file_statistics = $self->param('file_statistics');
    my $fh_statistics = FileHandle->new($file_statistics, 'w');

    foreach my $stats (qw/count_input_ids pre_count_unmapped pre_count_mapped stats_failed stats_unique_map stats_multi_map/) {
        my $count = $self->param($stats);
        print $fh_statistics "$stats=$count\n";
    }
    $fh_statistics->close();

}

sub join_feature_data {
    my $self = shift;

    my $file_init_feature = $self->param('file_init_feature');
    my $fh_init_feature = FileHandle->new($file_init_feature, 'r'); 
    
    my $feature_data = {};
    while (<$fh_init_feature>) {
        chomp;
        my $data = $self->read_data($_);
        my $variation_feature_id = $data->{variation_feature_id};
        $feature_data->{$variation_feature_id} = $data;
    }
    $fh_init_feature->close();

    # get new seq_region_ids
    my $seq_region_ids = {};
    my $cdba = $self->param('cdba');
    my $sa = $cdba->get_SliceAdaptor;
    my $slices = $sa->fetch_all('toplevel', undef, 1);
    foreach my $slice (@$slices) {
        $seq_region_ids->{$slice->seq_region_name} = $slice->get_seq_region_id;
    }
    # new map_weights
    my $file_filtered_mappings = $self->param('file_filtered_mappings');
    my $fh_mappings = FileHandle->new($file_filtered_mappings, 'r');
    my $map_weights = {};
    while (<$fh_mappings>) {
        chomp;
        my ($query_name, $seq_name, $start, $end, $strand, $score) = split("\t", $_);
        $map_weights->{$query_name}++;
    }
    $fh_mappings->close();

    # join feature data with mapping data:
   
    my $file_load_features = $self->param('file_load_features');
    my $fh_load_features = FileHandle->new($file_load_features, 'w');   
    $fh_mappings = FileHandle->new($file_filtered_mappings, 'r');

    while (<$fh_mappings>) {
        chomp;
        my ($query_name, $seq_name, $start, $end, $strand, $score) = split("\t", $_);
        # query_name: 156358-150-1-150-11:5502587:5502587:1:T/C:rs202026261:dbSNP:SNV
        my @query_name_components = split('-', $query_name, 2);
        my $variation_feature_id = $query_name_components[0];
        my $seq_region_id = $seq_region_ids->{$seq_name};
        my $map_weight = $map_weights->{$query_name};

        my $data = $feature_data->{$variation_feature_id};
        $data->{seq_region_id} = $seq_region_id;
        $data->{seq_region_start} = $start;
        $data->{seq_region_end} = $end;
        $data->{seq_region_strand} = $strand;
        $data->{alignment_quality} = $score;
        $data->{map_weight} = $map_weight;

        my $line = $self->print_complete_feature_line($data);
        
        print $fh_load_features $line, "\n"; 
    }

    $fh_mappings->close();
    $fh_load_features->close();
}

sub read_data {
    my $self = shift;
    my $line = shift;
    my @key_values = split("\t", $line);
    my $mapping = {};
    foreach my $key_value (@key_values) {
        my ($table_name, $value) = split('=', $key_value, 2);
        $mapping->{$table_name} = $value;
    }
    return $mapping;
}

sub print_feature_line {
    my ($self, $query_name, $new_seq_info, $score) = @_;
    my ($seq_name, $start, $end, $strand) = split(' ', $new_seq_info);
    my $line =  join("\t", ($query_name, $seq_name, $start, $end, $strand, $score));
    return $line;
}

# returns the row that will be loaded into the new variation_feature_table
# change variation_feature_id to old_variation_feature_id
sub print_complete_feature_line {
    my $self = shift;
    my $data = shift;
    my $variation_feature_id = $data->{variation_feature_id};
    $data->{variation_feature_id_old} = $variation_feature_id;
    my @output = ();
    foreach my $column_name (sort keys %$data) {
        unless ($column_name =~ /^variation_feature_id$/ || $column_name =~ /^seq_region_name$/) {
            push @output, $data->{$column_name};
        }
    }
    my $line = join("\t", @output);
    return $line;
}


1;