package Koha::Plugin::HKS3::PatronNaturalSearch;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use CGI;
use C4::Context;
use Koha::Libraries;
use Koha::Patrons;
use Koha::Patron::Categories;
use Koha::Patron::Modifications;
use Mojo::JSON qw(decode_json);

our $VERSION = '0.1.0';

our $metadata = {
    name            => 'Patron Natural Search',
    author          => 'OpenAI Codex',
    description     => 'MariaDB natural-language patron search API using FULLTEXT indexes',
    namespace       => 'patron_natural_search',
    date_authored   => '2026-05-22',
    date_updated    => '2026-05-22',
    minimum_version => '23.11',
    maximum_version => undef,
    version         => $VERSION,
};

my $INDEX_TABLE = 'plugin_patron_natural_search';

my @BORROWERS_FULLTEXT_FIELDS = qw(
    cardnumber surname firstname preferred_name middle_name title othernames initials pronouns
    streetnumber streettype address address2 city state zipcode country
    email phone mobile fax emailpro phonepro
    B_streetnumber B_streettype B_address B_address2 B_city B_state B_zipcode B_country B_email B_phone
    debarredcomment contactname contactfirstname contacttitle borrowernotes relationship userid opacnote contactnote
    sort1 sort2 altcontactfirstname altcontactsurname altcontactaddress1 altcontactaddress2 altcontactaddress3
    altcontactstate altcontactzipcode altcontactcountry altcontactphone smsalertnumber primary_contact_method
);

my @ALL_BORROWER_EXTRA_FIELDS = qw(branchcode categorycode);

my %BORROWER_GROUPS = (
    standard     => [qw(firstname preferred_name middle_name surname othernames cardnumber userid)],
    full_address => [qw(streetnumber streettype address address2 city state zipcode country)],
    all_emails   => [qw(email emailpro B_email)],
    all_phones   => [qw(phone phonepro B_phone altcontactphone mobile)],
);

sub new {
    my ( $class, $args ) = @_;

    $args->{metadata}        = $metadata;
    $args->{metadata}{class} = $class;

    my $self = $class->SUPER::new($args);
    $self->{cgi} = CGI->new;

    return $self;
}

sub api_namespace {
    return 'patron_natural_search';
}

sub api_routes {
    my ($self) = @_;
    return decode_json( $self->mbf_read('openapi.json') );
}

sub tool {
    my ($self) = @_;

    my $no_add = 0;
    my %template_params;

    if ( Koha::Libraries->search->count < 1 ) {
        $no_add = 1;
        $template_params{no_branches} = 1;
    }

    my $categories = Koha::Patron::Categories->search_with_library_limits;
    if ( !$categories->count ) {
        $no_add = 1;
        $template_params{no_categories} = 1;
    }

    $template_params{no_add} = $no_add;
    $template_params{pending_borrower_modifications} = Koha::Patron::Modifications->pending_count;

    my $attribute_search_options = [];
    if ( C4::Context->preference('ExtendedPatronAttributes') ) {
        $attribute_search_options = C4::Context->dbh->selectall_arrayref(
            q{
                SELECT code, description, searched_by_default
                FROM borrower_attribute_types
                WHERE staff_searchable = 1
                ORDER BY description, code
            },
            { Slice => {} }
        );
    }

    my $template = $self->get_template( { file => 'tool.tt' } );
    $template->param(
        %template_params,
        api_search_url          => '/api/v1/contrib/patron_natural_search/patrons',
        attribute_search_options => $attribute_search_options,
    );

    return $self->output_html( $template->output );
}

sub install {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;

    $self->_create_index_table($dbh);
    $self->rebuild_index;
    $self->_install_triggers($dbh);

    return 1;
}

sub upgrade {
    my ($self) = @_;
    return $self->install;
}

sub rebuild_index {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;

    $dbh->do( 'DELETE FROM ' . $dbh->quote_identifier($INDEX_TABLE) );

    for my $field (@BORROWERS_FULLTEXT_FIELDS) {
        next unless _column_exists( $dbh, 'borrowers', $field );
        $dbh->do( _insert_select_sql( $dbh, $field, [$field] ) );
    }

    for my $group ( sort keys %BORROWER_GROUPS ) {
        my @fields = grep { _column_exists( $dbh, 'borrowers', $_ ) } @{ $BORROWER_GROUPS{$group} };
        next unless @fields;
        $dbh->do( _insert_select_sql( $dbh, $group, \@fields ) );
    }

    if ( _column_exists( $dbh, 'borrower_attributes', 'attribute' ) ) {
        $dbh->do(
            sprintf(
                q{
                    INSERT INTO %s (borrowernumber, field_group, content)
                    SELECT borrowernumber, CONCAT('_ATTR_', code), GROUP_CONCAT(attribute SEPARATOR ' ')
                    FROM borrower_attributes
                    WHERE attribute IS NOT NULL
                      AND attribute <> ''
                    GROUP BY borrowernumber, code
                },
                $dbh->quote_identifier($INDEX_TABLE)
            )
        );
    }

    $dbh->do( _insert_all_select_sql($dbh) );

    return 1;
}

sub uninstall {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;

    for my $trigger (
        qw(
        pns_borrowers_ai pns_borrowers_au pns_borrowers_ad
        pns_borrower_attributes_ai pns_borrower_attributes_au pns_borrower_attributes_ad
        )
        )
    {
        $dbh->do( 'DROP TRIGGER IF EXISTS ' . $dbh->quote_identifier($trigger) );
    }

    $dbh->do( 'DROP TABLE IF EXISTS ' . $dbh->quote_identifier($INDEX_TABLE) );

    return 1;
}

sub _create_index_table {
    my ( $self, $dbh ) = @_;

    $dbh->do(
        sprintf(
            q{
                CREATE TABLE IF NOT EXISTS %s (
                    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
                    borrowernumber INT(11) NOT NULL,
                    field_group VARCHAR(80) NOT NULL,
                    content LONGTEXT NOT NULL,
                    updated_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                    PRIMARY KEY (id),
                    KEY pns_borrowernumber (borrowernumber),
                    KEY pns_group_borrowernumber (field_group, borrowernumber),
                    FULLTEXT KEY pns_ft_content (content)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
            },
            $dbh->quote_identifier($INDEX_TABLE)
        )
    );

    return;
}

sub _column_exists {
    my ( $dbh, $table, $column ) = @_;

    my ($exists) = $dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM information_schema.columns
            WHERE table_schema = DATABASE()
              AND table_name = ?
              AND column_name = ?
        },
        undef,
        $table,
        $column
    );

    return $exists ? 1 : 0;
}

sub _install_triggers {
    my ( $self, $dbh ) = @_;

    for my $trigger (
        qw(
        pns_borrowers_ai pns_borrowers_au pns_borrowers_ad
        pns_borrower_attributes_ai pns_borrower_attributes_au pns_borrower_attributes_ad
        )
        )
    {
        $dbh->do( 'DROP TRIGGER IF EXISTS ' . $dbh->quote_identifier($trigger) );
    }

    my $borrower_refresh = _borrower_refresh_sql( $dbh, 'NEW' );

    $dbh->do(
        sprintf(
            q{
                CREATE TRIGGER pns_borrowers_ai AFTER INSERT ON borrowers
                FOR EACH ROW
                BEGIN
                    %s
                END
            },
            $borrower_refresh
        )
    );

    $dbh->do(
        sprintf(
            q{
                CREATE TRIGGER pns_borrowers_au AFTER UPDATE ON borrowers
                FOR EACH ROW
                BEGIN
                    DELETE FROM %s
                    WHERE borrowernumber = NEW.borrowernumber
                      AND field_group NOT LIKE '\_ATTR\_%%';
                    %s
                END
            },
            $dbh->quote_identifier($INDEX_TABLE),
            $borrower_refresh
        )
    );

    $dbh->do(
        sprintf(
            q{
                CREATE TRIGGER pns_borrowers_ad AFTER DELETE ON borrowers
                FOR EACH ROW
                BEGIN
                    DELETE FROM %s WHERE borrowernumber = OLD.borrowernumber;
                END
            },
            $dbh->quote_identifier($INDEX_TABLE)
        )
    );

    if ( _column_exists( $dbh, 'borrower_attributes', 'attribute' ) ) {
        $dbh->do(
            sprintf(
                q{
                    CREATE TRIGGER pns_borrower_attributes_ai AFTER INSERT ON borrower_attributes
                    FOR EACH ROW
                    BEGIN
                        %s
                    END
                },
                _attribute_refresh_sql( $dbh, 'NEW' )
            )
        );

        $dbh->do(
            sprintf(
                q{
                    CREATE TRIGGER pns_borrower_attributes_au AFTER UPDATE ON borrower_attributes
                    FOR EACH ROW
                    BEGIN
                        %s
                        %s
                    END
                },
                _attribute_refresh_sql( $dbh, 'OLD' ),
                _attribute_refresh_sql( $dbh, 'NEW' )
            )
        );

        $dbh->do(
            sprintf(
                q{
                    CREATE TRIGGER pns_borrower_attributes_ad AFTER DELETE ON borrower_attributes
                    FOR EACH ROW
                    BEGIN
                        %s
                    END
                },
                _attribute_refresh_sql( $dbh, 'OLD' )
            )
        );
    }

    return;
}

sub _insert_select_sql {
    my ( $dbh, $group, $fields ) = @_;

    my $content_sql = _concat_ws_sql( $dbh, 'b', $fields );

    return sprintf(
        q{
            INSERT INTO %s (borrowernumber, field_group, content)
            SELECT borrowernumber, %s, content
            FROM (
                SELECT b.borrowernumber, %s AS content
                FROM borrowers b
            ) pns_source
            WHERE content IS NOT NULL
              AND content <> ''
        },
        $dbh->quote_identifier($INDEX_TABLE),
        $dbh->quote($group),
        $content_sql
    );
}

sub _borrower_refresh_sql {
    my ( $dbh, $row_alias ) = @_;

    my @statements;

    for my $field (@BORROWERS_FULLTEXT_FIELDS) {
        next unless _column_exists( $dbh, 'borrowers', $field );
        push @statements, _insert_from_row_sql( $dbh, $row_alias, $field, [$field] );
    }

    for my $group ( sort keys %BORROWER_GROUPS ) {
        my @fields = grep { _column_exists( $dbh, 'borrowers', $_ ) } @{ $BORROWER_GROUPS{$group} };
        next unless @fields;
        push @statements, _insert_from_row_sql( $dbh, $row_alias, $group, \@fields );
    }

    push @statements, _insert_all_from_row_sql( $dbh, $row_alias );

    return join "\n", @statements;
}

sub _insert_from_row_sql {
    my ( $dbh, $row_alias, $group, $fields ) = @_;

    my $content_sql = _concat_ws_sql( $dbh, $row_alias, $fields );

    return sprintf(
        q{
            INSERT INTO %s (borrowernumber, field_group, content)
            SELECT %s.borrowernumber, %s, %s
            WHERE %s <> '';
        },
        $dbh->quote_identifier($INDEX_TABLE),
        $row_alias,
        $dbh->quote($group),
        $content_sql,
        $content_sql
    );
}

sub _attribute_refresh_sql {
    my ( $dbh, $row_alias ) = @_;

    return sprintf(
        q{
            DELETE FROM %s
            WHERE borrowernumber = %s.borrowernumber
              AND field_group = CONCAT('_ATTR_', %s.code);

            INSERT INTO %s (borrowernumber, field_group, content)
            SELECT borrowernumber, CONCAT('_ATTR_', code), GROUP_CONCAT(attribute SEPARATOR ' ')
            FROM borrower_attributes
            WHERE borrowernumber = %s.borrowernumber
              AND code = %s.code
              AND attribute IS NOT NULL
              AND attribute <> ''
            GROUP BY borrowernumber, code;

            %s
        },
        $dbh->quote_identifier($INDEX_TABLE),
        $row_alias,
        $row_alias,
        $dbh->quote_identifier($INDEX_TABLE),
        $row_alias,
        $row_alias,
        _all_refresh_for_borrowernumber_sql( $dbh, "$row_alias.borrowernumber" )
    );
}

sub _insert_all_select_sql {
    my ($dbh) = @_;

    my $content_sql = _all_content_sql( $dbh, 'b', 'b.borrowernumber' );

    return sprintf(
        q{
            INSERT INTO %s (borrowernumber, field_group, content)
            SELECT borrowernumber, 'all', content
            FROM (
                SELECT b.borrowernumber, %s AS content
                FROM borrowers b
            ) pns_all_source
            WHERE content IS NOT NULL
              AND content <> ''
        },
        $dbh->quote_identifier($INDEX_TABLE),
        $content_sql
    );
}

sub _insert_all_from_row_sql {
    my ( $dbh, $row_alias ) = @_;

    my $content_sql = _all_content_sql( $dbh, $row_alias, "$row_alias.borrowernumber" );

    return sprintf(
        q{
            INSERT INTO %s (borrowernumber, field_group, content)
            SELECT %s.borrowernumber, 'all', %s
            WHERE %s <> '';
        },
        $dbh->quote_identifier($INDEX_TABLE),
        $row_alias,
        $content_sql,
        $content_sql
    );
}

sub _all_refresh_for_borrowernumber_sql {
    my ( $dbh, $borrowernumber_expr ) = @_;

    my $content_sql = _all_content_sql( $dbh, 'b', 'b.borrowernumber' );

    return sprintf(
        q{
            DELETE FROM %s
            WHERE borrowernumber = %s
              AND field_group = 'all';

            INSERT INTO %s (borrowernumber, field_group, content)
            SELECT b.borrowernumber, 'all', %s
            FROM borrowers b
            WHERE b.borrowernumber = %s
              AND %s <> '';
        },
        $dbh->quote_identifier($INDEX_TABLE),
        $borrowernumber_expr,
        $dbh->quote_identifier($INDEX_TABLE),
        $content_sql,
        $borrowernumber_expr,
        $content_sql
    );
}

sub _all_content_sql {
    my ( $dbh, $borrower_alias, $borrowernumber_expr ) = @_;

    my @borrower_fields = grep { _column_exists( $dbh, 'borrowers', $_ ) }
        _uniq( @BORROWERS_FULLTEXT_FIELDS, @ALL_BORROWER_EXTRA_FIELDS );

    my @parts;
    push @parts, _concat_ws_sql( $dbh, $borrower_alias, \@borrower_fields )
        if @borrower_fields;

    if ( _column_exists( $dbh, 'borrower_attributes', 'attribute' ) ) {
        push @parts, sprintf(
            q{
                (
                    SELECT GROUP_CONCAT(
                        TRIM(CONCAT_WS(' ', NULLIF(ba.code, ''), NULLIF(ba.attribute, '')))
                        ORDER BY ba.code, ba.attribute
                        SEPARATOR ' '
                    )
                    FROM borrower_attributes ba
                    WHERE ba.borrowernumber = %s
                      AND ba.attribute IS NOT NULL
                      AND ba.attribute <> ''
                )
            },
            $borrowernumber_expr
        );
    }

    return q{''} unless @parts;

    return sprintf( "TRIM(CONCAT_WS(' ', %s))", join( ', ', @parts ) );
}

sub _concat_ws_sql {
    my ( $dbh, $alias, $fields ) = @_;

    return sprintf(
        "TRIM(CONCAT_WS(' ', %s))",
        join(
            ', ',
            map { 'NULLIF(' . $alias . '.' . $dbh->quote_identifier($_) . ", '')" } @{$fields}
        )
    );
}

sub _uniq {
    my %seen;
    return grep { !$seen{$_}++ } @_;
}

1;
