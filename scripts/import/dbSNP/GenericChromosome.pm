use strict;
use warnings;
#object that contains the specific methods to dump data when there are chromosome coordinates from dbSNP (not contigs, as usual). 
#So far, this is the case for rat and chicken
package dbSNP::GenericChromosome;

use dbSNP::GenericContig;
use vars qw(@ISA);
use ImportUtils qw(debug load dumpSQL create_and_load);

@ISA = ('dbSNP::GenericContig');

sub variation_feature{
    my $self = shift;

    ### TBD not sure if variations with map_weight > 1 or 2 should be
    ### imported.
    
    debug("Dumping seq_region data");

    #only take toplevel coordinates
    dumpSQL($self->{'dbCore'}->dbc()->db_handle, qq{SELECT sr.seq_region_id, 
 				      if (sr.name like "E%", CONCAT("LG",sr.name),sr.name) ##add LG for chicken
 				      FROM   seq_region_attrib sra, attrib_type at, seq_region sr
 				      WHERE sra.attrib_type_id=at.attrib_type_id 
	                              AND at.code="toplevel" 
                                      AND sr.seq_region_id = sra.seq_region_id 
				    });

    debug("Loading seq_region data");
    create_and_load($self->{'dbVariation'}, "tmp_seq_region", "seq_region_id", "name *");
    
    debug("Dumping SNPLoc data");
    
    my ($tablename1,$tablename2,$row);

    print "assembly_version is ",$self->{'assembly_version'},"\n";
    my ($assembly_version) =  $self->{'assembly_version'} =~ /^[a-zA-Z]+(\d+)\.*.*$/;
    $assembly_version=1;
    my $sth = $self->{'dbSNP'}->prepare(qq{SHOW TABLES LIKE 
					   '$self->{'dbSNP_version'}\_SNPContigLoc\_$assembly_version\__'});
    $sth->execute();

    while($row = $sth->fetchrow_arrayref()) {
      $tablename1 = $row->[0];
    }

    my $sth1 = $self->{'dbSNP'}->prepare(qq{SHOW TABLES LIKE 
					   '$self->{'dbSNP_version'}\_ContigInfo\_$assembly_version\__'});
    $sth1->execute();

    while($row = $sth1->fetchrow_arrayref()) {
      $tablename2 = $row->[0];
    }
    print "table_name1 is $tablename1 table_name2 is $tablename2\n";
    #my $tablename = $self->{'species_prefix'} . 'SNPContigLoc';
    dumpSQL($self->{'dbSNP'}, qq{SELECT t1.snp_id, t2.contig_acc,t1.lc_ngbr+2,t1.rc_ngbr,
				 IF(t2.group_term like "ref_%",t2.contig_chr,t2.contig_label), 
				 IF(t1.loc_type = 3, t1.phys_pos_from+2, t1.phys_pos_from+1),
				 IF(t1.loc_type = 3,  t1.phys_pos_from+1, t1.phys_pos_from+length(t1.allele)),
				 IF(t1.orientation, -1, 1)
				 FROM $tablename1 t1, $tablename2 t2 
				 WHERE t1.ctg_id = t2.ctg_id
				 #AND t2.group_term like "ref_%"
				 $self->{'limit'}});
    
    
   debug("Loading SNPLoc data");
    
    create_and_load($self->{'dbVariation'}, "tmp_contig_loc_chrom", "snp_id i*", "ctg *", "ctg_start i", "ctg_end i", "chr *", "start i", "end i", "strand i");

    debug("Creating genotyped variations");
    #creating the temporary table with the genotyped variations

     $self->{'dbVariation'}->do(qq{CREATE TABLE tmp_genotyped_var SELECT DISTINCT variation_id FROM tmp_individual_genotype_single_bp});
     $self->{'dbVariation'}->do(qq{CREATE UNIQUE INDEX variation_idx ON tmp_genotyped_var (variation_id)});
     $self->{'dbVariation'}->do(qq{INSERT IGNORE INTO tmp_genotyped_var SELECT DISTINCT variation_id FROM individual_genotype_multiple_bp});

    debug("Creating tmp_variation_feature_chrom data");
    
    dumpSQL($self->{'dbVariation'},qq{SELECT v.variation_id, ts.seq_region_id, 
                                      tcl.start,tcl.end,
                                      tcl.strand, v.name, v.source_id, v.validation_status
				      FROM variation v, tmp_contig_loc_chrom tcl, tmp_seq_region ts
				      WHERE v.snp_id = tcl.snp_id
				      AND tcl.end>1
                                      AND tcl.chr = ts.name
    });

    create_and_load($self->{'dbVariation'},'tmp_variation_feature_chrom',"variation_id *","seq_region_id", "seq_region_start", "seq_region_end", "seq_region_strand", "variation_name", "source_id", "validation_status");
    
    debug("Creating tmp_variation_feature_ctg data");
    
    dumpSQL($self->{'dbVariation'},qq{SELECT v.variation_id, ts.seq_region_id, 
                                      tcl.ctg_start,tcl.ctg_end,
                                      tcl.strand, v.name, v.source_id, v.validation_status
				      FROM variation v, tmp_contig_loc_chrom tcl, tmp_seq_region ts
				      WHERE v.snp_id = tcl.snp_id
				      AND (tcl.start = 1 or tcl.end=1)
                                      AND tcl.ctg = ts.name
   });

    create_and_load($self->{'dbVariation'},'tmp_variation_feature_ctg',"variation_id *","seq_region_id", "seq_region_start", "seq_region_end", "seq_region_strand", "variation_name", "source_id", "validation_status");

    debug("Dumping data into variation_feature table");
    $self->{'dbVariation'}->do(qq{INSERT INTO variation_feature (variation_id, seq_region_id,seq_region_start, seq_region_end, seq_region_strand,variation_name, flags, source_id, validation_status)
				  SELECT tvf.variation_id, tvf.seq_region_id, tvf.seq_region_start, tvf.seq_region_end, tvf.seq_region_strand,tvf.variation_name,IF(tgv.variation_id,'genotyped',NULL), tvf.source_id, tvf.validation_status
				  FROM tmp_variation_feature_chrom tvf LEFT JOIN tmp_genotyped_var tgv ON tvf.variation_id = tgv.variation_id
				  });

    debug("Dumping data into variation_feature table");
    $self->{'dbVariation'}->do(qq{INSERT INTO variation_feature (variation_id, seq_region_id,seq_region_start, seq_region_end, seq_region_strand,variation_name, flags, source_id, validation_status)
				  SELECT tvf.variation_id, tvf.seq_region_id, tvf.seq_region_start, tvf.seq_region_end, tvf.seq_region_strand,tvf.variation_name,NULL, tvf.source_id, tvf.validation_status
				  FROM tmp_variation_feature_chrom tvf
				  });
    debug("Dumping data into variation_feature table");
    $self->{'dbVariation'}->do(qq{INSERT INTO variation_feature (variation_id, seq_region_id,seq_region_start, seq_region_end, seq_region_strand,variation_name, flags, source_id, validation_status)
				  SELECT tvf.variation_id, tvf.seq_region_id, tvf.seq_region_start, tvf.seq_region_end, tvf.seq_region_strand,tvf.variation_name,NULL, tvf.source_id, tvf.validation_status
				  FROM tmp_variation_feature_ctg tvf
				  });

    #$self->{'dbVariation'}->do("DROP TABLE tmp_contig_loc");
    #$self->{'dbVariation'}->do("DROP TABLE tmp_seq_region");
    #$self->{'dbVariation'}->do("DROP TABLE tmp_genotyped_var");
    #$self->{'dbVariation'}->do("DROP TABLE tmp_variation_feature_chrom");
    #$self->{'dbVariation'}->do("DROP TABLE tmp_variation_feature_ctg");
    #for the chicken, delete 13,000 SNPs that cannot be mapped to EnsEMBL coordinate
    if ($self->{'dbCore'}->species =~ /gga/i){
	$self->{'dbVariation'}->do("DELETE FROM variation_feature WHERE seq_region_end = -1");
    }
}

1;
