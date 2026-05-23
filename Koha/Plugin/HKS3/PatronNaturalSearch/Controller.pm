package Koha::Plugin::HKS3::PatronNaturalSearch::Controller;

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use C4::Context;
use Koha::Patrons;
use Mojo::JSON;
use Try::Tiny qw(catch try);

my @STANDARD_FIELDS = qw(firstname preferred_name middle_name surname othernames cardnumber userid);
my $INDEX_TABLE = 'plugin_patron_natural_search';

my %FIELD_ALIASES = (
    patron_id                  => 'borrowernumber',
    street_number             => 'streetnumber',
    street_type               => 'streettype',
    postal_code               => 'zipcode',
    secondary_email           => 'emailpro',
    secondary_phone           => 'phonepro',
    altaddress_street_number  => 'B_streetnumber',
    altaddress_street_type    => 'B_streettype',
    altaddress_address        => 'B_address',
    altaddress_address2       => 'B_address2',
    altaddress_city           => 'B_city',
    altaddress_state          => 'B_state',
    altaddress_postal_code    => 'B_zipcode',
    altaddress_country        => 'B_country',
    altaddress_email          => 'B_email',
    altaddress_phone          => 'B_phone',
    date_of_birth             => 'dateofbirth',
    library_id                => 'branchcode',
    category_id               => 'categorycode',
    date_enrolled             => 'dateenrolled',
    expiry_date               => 'dateexpiry',
    incorrect_address         => 'gonenoaddress',
    patron_card_lost          => 'lost',
    staff_notes               => 'borrowernotes',
    relationship_type         => 'relationship',
    gender                    => 'sex',
    opac_notes                => 'opacnote',
    altaddress_notes          => 'contactnote',
    statistics_1              => 'sort1',
    statistics_2              => 'sort2',
    altcontact_firstname      => 'altcontactfirstname',
    altcontact_surname        => 'altcontactsurname',
    altcontact_address        => 'altcontactaddress1',
    altcontact_address2       => 'altcontactaddress2',
    altcontact_city           => 'altcontactaddress3',
    altcontact_state          => 'altcontactstate',
    altcontact_postal_code    => 'altcontactzipcode',
    altcontact_country        => 'altcontactcountry',
    altcontact_phone          => 'altcontactphone',
    sms_number                => 'smsalertnumber',
    check_previous_checkout   => 'checkprevcheckout',
);

my %GROUPS = (
    all => [],
    full_address => [
        qw(streetnumber streettype address address2 city state zipcode country)
    ],
    all_emails => [
        qw(email emailpro B_email)
    ],
    all_phones => [
        qw(phone phonepro B_phone altcontactphone mobile)
    ],
);

my %FULLTEXT_FIELDS = map { $_ => 1 } qw(
    cardnumber surname firstname preferred_name middle_name title othernames initials pronouns
    streetnumber streettype address address2 city state zipcode country
    email phone mobile fax emailpro phonepro
    B_streetnumber B_streettype B_address B_address2 B_city B_state B_zipcode B_country B_email B_phone
    debarredcomment contactname contactfirstname contacttitle borrowernotes relationship userid opacnote contactnote
    sort1 sort2 altcontactfirstname altcontactsurname altcontactaddress1 altcontactaddress2 altcontactaddress3
    altcontactstate altcontactzipcode altcontactcountry altcontactphone smsalertnumber primary_contact_method
);

my %FILTERABLE_FIELDS = map { $_ => 1 } qw(
    borrowernumber branchcode categorycode dateofbirth dateenrolled dateexpiry
    gonenoaddress lost debarred sex sms_provider_id privacy privacy_guarantor_checkouts
    checkprevcheckout updated_on lastseen login_attempts protected
);

my %FIELD_WEIGHT = (
    borrowernumber   => 50,
    cardnumber       => 20,
    userid           => 12,
    surname          => 8,
    firstname        => 7,
    preferred_name   => 7,
    middle_name      => 5,
    othernames       => 5,
    email            => 3,
    emailpro         => 3,
    B_email          => 3,
    phone            => 3,
    phonepro         => 3,
    B_phone          => 3,
    mobile           => 3,
    smsalertnumber   => 3,
    borrowernotes    => 1,
    opacnote         => 1,
);

sub search {
    my $c = shift->openapi->valid_input or return;

    return try {
        my $dbh = C4::Context->dbh;

        my $query = _trim(
               $c->validation->param('query')
            // $c->validation->param('q')
            // $c->validation->param('searchmember')
            // q{}
        );

        my $field_selector =
               $c->validation->param('searchfieldstype')
            // $c->validation->param('search_fields')
            // 'standard';
        my $search_type   = $c->validation->param('searchtype') // $c->validation->param('search_type') // 'natural';
        my $fallback_like = _boolean( $c->validation->param('fallback_like') );
        my $match_mode_param = $c->validation->param('match_mode') // $c->validation->param('fulltext_mode');
        $match_mode_param = 'boolean' if _boolean( $c->validation->param('boolean_mode') );
        my ( $match_mode, $match_mode_warning ) = _match_mode($match_mode_param);
        my $draw          = _bounded_int( $c->validation->param('draw'), 0, 0, 1000000 );
        my $dt_start      = $c->validation->param('start');
        my $dt_length     = $c->validation->param('length');
        my $per_page      = _bounded_int( $c->validation->param('_per_page') // $c->validation->param('per_page') // $dt_length, 20, 1, 100 );
        my $page          = _bounded_int( $c->validation->param('_page') // $c->validation->param('page'), 1, 1, 100000 );
        if ( defined $dt_start && length $dt_start ) {
            my $start = _bounded_int( $dt_start, 0, 0, 10000000 );
            $page = int( $start / $per_page ) + 1;
        }
        my $offset        = ( $page - 1 ) * $per_page;

        my ( $fields, $search_groups, $warnings ) = _expand_search_fields($field_selector);
        push @{$warnings}, $match_mode_warning if $match_mode_warning;

        my @where;
        my @where_bind;

        my ( $match_sql, @match_bind ) = _match_where_sql(
            $dbh,
            {
                query           => $query,
                fields          => $fields,
                search_groups   => $search_groups,
                fallback_like   => $fallback_like,
                search_type     => $search_type,
                match_mode      => $match_mode,
            }
        );
        if ($match_sql) {
            push @where,      $match_sql;
            push @where_bind, @match_bind;
        }

        my @restricted_branchcodes = _restricted_branchcodes($c);
        if (@restricted_branchcodes) {
            push @where, 'b.branchcode IN (' . join( ',', ('?') x @restricted_branchcodes ) . ')';
            push @where_bind, @restricted_branchcodes;
        }

        _add_simple_filter( \@where, \@where_bind, 'b.branchcode',    $c->validation->param('library_id')  // $c->validation->param('branchcode_filter') );
        _add_simple_filter( \@where, \@where_bind, 'b.categorycode',  $c->validation->param('category_id') // $c->validation->param('categorycode_filter') );
        _add_simple_filter( \@where, \@where_bind, 'b.sort1',         $c->validation->param('sort1')       // $c->validation->param('sort1_filter') );
        _add_simple_filter( \@where, \@where_bind, 'b.sort2',         $c->validation->param('sort2')       // $c->validation->param('sort2_filter') );

        if ( defined $c->validation->param('firstletter') && length $c->validation->param('firstletter') ) {
            push @where,      'b.surname LIKE ?';
            push @where_bind, $c->validation->param('firstletter') . '%';
        }

        _add_like_filter( \@where, \@where_bind, 'b.cardnumber', $c->validation->param('column_cardnumber') );
        _add_multi_like_filter(
            \@where, \@where_bind,
            [
                qw(
                    b.surname b.firstname b.preferred_name b.middle_name b.othernames
                    b.streetnumber b.streettype b.address b.address2 b.city b.state b.zipcode b.country b.email
                )
            ],
            $c->validation->param('column_name')
        );
        _add_multi_like_filter(
            \@where, \@where_bind,
            [qw(b.phone b.mobile b.phonepro b.B_phone b.altcontactphone)],
            $c->validation->param('column_phone')
        );
        _add_like_filter( \@where, \@where_bind, 'CAST(b.dateofbirth AS CHAR)', $c->validation->param('column_date_of_birth') );
        _add_simple_filter( \@where, \@where_bind, 'b.branchcode',             $c->validation->param('column_library') );
        _add_simple_filter( \@where, \@where_bind, 'b.categorycode',           $c->validation->param('column_category') );
        _add_like_filter( \@where, \@where_bind, 'CAST(b.dateexpiry AS CHAR)', $c->validation->param('column_expiry_date') );
        _add_like_filter( \@where, \@where_bind, _checkouts_filter_sql(),      $c->validation->param('column_checkouts') );
        _add_like_filter( \@where, \@where_bind, _account_balance_filter_sql(), $c->validation->param('column_account_balance') );
        _add_like_filter( \@where, \@where_bind, 'b.borrowernotes',            $c->validation->param('column_staff_notes') );
        _add_simple_filter( \@where, \@where_bind, 'b.sort1',                  $c->validation->param('column_statistics_1') );
        _add_simple_filter( \@where, \@where_bind, 'b.sort2',                  $c->validation->param('column_statistics_2') );
        _add_attribute_filter( \@where, \@where_bind, $c->validation->param('column_attributes') );

        my ( $score_sql, @score_bind ) = _score_sql(
            $dbh,
            {
                query           => $query,
                fields          => $fields,
                search_groups   => $search_groups,
                match_mode      => $match_mode,
            }
        );

        my $where_sql = @where ? 'WHERE ' . join( ' AND ', @where ) : q{};
        my $from_sql  = "FROM borrowers b $where_sql";

        my ($total) = $dbh->selectrow_array( "SELECT COUNT(*) $from_sql", undef, @where_bind );
        $total //= 0;

        my $sql = qq{
            SELECT b.borrowernumber, $score_sql AS natural_score
            $from_sql
            ORDER BY natural_score DESC, b.surname, b.firstname, b.borrowernumber
            LIMIT ? OFFSET ?
        };

        my $sth = $dbh->prepare($sql);
        $sth->execute( @score_bind, @where_bind, $per_page, $offset );

        my @rows = @{ $sth->fetchall_arrayref( {} ) };
        my @ids  = map { $_->{borrowernumber} } @rows;
        my %score_by_id = map { $_->{borrowernumber} => 0 + ( $_->{natural_score} // 0 ) } @rows;

        my %patron_by_id;
        if (@ids) {
            my $patrons = Koha::Patrons->search( { borrowernumber => { -in => \@ids } } );
            %patron_by_id = map { $_->borrowernumber => $_ } $patrons->as_list;
        }

        my $user = $c->stash('koha.user');
        my ( $embed, $strings ) = _embed_from_header( $c->req->headers->header('x-koha-embed') );
        my %api_params = ( user => $user );
        $api_params{embed}   = $embed   if $embed;
        $api_params{strings} = $strings if $strings;
        my @data;
        for my $id (@ids) {
            my $patron = $patron_by_id{$id} or next;
            my $record = $patron->to_api( \%api_params );
            $record->{natural_score} = sprintf( '%.6f', $score_by_id{$id} // 0 ) + 0;
            push @data, $record;
        }

        $c->res->headers->add( 'X-Total-Count' => $total );

        return $c->render(
            status  => 200,
            openapi => {
                query           => $query,
                searchfieldstype => $field_selector,
                search_type     => $search_type,
                match_mode      => $match_mode,
                fallback_like   => $fallback_like ? Mojo::JSON->true : Mojo::JSON->false,
                page            => $page,
                per_page        => $per_page,
                count           => scalar @data,
                total           => 0 + $total,
                draw            => 0 + $draw,
                recordsTotal    => 0 + $total,
                recordsFiltered => 0 + $total,
                warnings        => $warnings,
                data            => \@data,
            },
        );
    }
    catch {
        return $c->render(
            status  => 500,
            openapi => {
                error      => "$_",
                error_code => 'patron_natural_search_failed',
            },
        );
    };
}

sub _expand_search_fields {
    my ($selector) = @_;

    my @fields;
    my @search_groups;
    my @warnings;

    my @selectors = grep { length } split /[|,]/, ( $selector // 'standard' );
    @selectors = ('standard') unless @selectors;

    for my $raw (@selectors) {
        my $item = _trim($raw);
        next unless length $item;

        if ( $item eq 'standard' ) {
            push @fields, _default_standard_fields();
            push @search_groups, 'standard';
            push @search_groups, _default_standard_attribute_groups();
        } elsif ( exists $GROUPS{$item} ) {
            push @fields, @{ $GROUPS{$item} };
            push @search_groups, $item;
        } elsif ( $item =~ /^_ATTR_(.+)$/ ) {
            push @search_groups, "_ATTR_$1";
        } else {
            my $field = $FIELD_ALIASES{$item} // $item;
            if ( $FULLTEXT_FIELDS{$field} || $FILTERABLE_FIELDS{$field} ) {
                push @fields, $field;
                push @search_groups, $field if $FULLTEXT_FIELDS{$field};
            } else {
                push @warnings, "Unsupported search field '$item' ignored";
            }
        }
    }

    @fields          = _uniq(@fields);
    @search_groups   = _uniq(@search_groups);

    return ( \@fields, \@search_groups, \@warnings );
}

sub _embed_from_header {
    my ($header) = @_;

    my %embed;
    my $strings = 0;

    for my $requested ( split /\s*,\s*/, $header // q{} ) {
        next unless length $requested;

        if ( $requested eq '+strings' ) {
            $strings = 1;
        } elsif ( $requested =~ /^(checkouts|overdues)\+count$/ ) {
            $embed{ $1 . '_count' } = { is_count => 1 };
        } elsif ( $requested =~ /^(account_balance|extended_attributes|library)$/ ) {
            $embed{$1} = {};
        }
    }

    return ( keys %embed ? \%embed : undef, $strings );
}

sub _default_standard_fields {
    my $pref = C4::Context->preference('DefaultPatronSearchFields')
        || join( '|', @STANDARD_FIELDS );

    my @fields;
    for my $field ( split /\|/, $pref ) {
        $field = _trim($field);
        next unless length $field;
        push @fields, $FIELD_ALIASES{$field} // $field;
    }

    return grep { $FULLTEXT_FIELDS{$_} || $FILTERABLE_FIELDS{$_} } @fields;
}

sub _default_standard_attribute_groups {
    return unless C4::Context->preference('ExtendedPatronAttributes');

    my $dbh = C4::Context->dbh;
    my $attribute_groups = $dbh->selectcol_arrayref(
        q{
            SELECT CONCAT('_ATTR_', code)
            FROM borrower_attribute_types
            WHERE staff_searchable = 1
              AND searched_by_default = 1
            ORDER BY code
        }
    );

    return @{ $attribute_groups // [] };
}

sub _match_where_sql {
    my ( $dbh, $args ) = @_;

    my $query = $args->{query};
    return unless defined $query && length $query;

    my @or;
    my @bind;

    if ( @{ $args->{search_groups} } ) {
        my $fulltext_mode_sql = _fulltext_mode_sql( $args->{match_mode} );
        my $group_sql = join( ',', ('?') x @{ $args->{search_groups} } );
        push @or, qq{
            EXISTS (
                SELECT 1
                FROM @{[ $dbh->quote_identifier($INDEX_TABLE) ]} pns_match
                WHERE pns_match.borrowernumber = b.borrowernumber
                  AND pns_match.field_group IN ($group_sql)
                  AND MATCH(pns_match.content) AGAINST (? $fulltext_mode_sql)
            )
        };
        push @bind, @{ $args->{search_groups} }, $query;
    }

    my ( $fallback_sql, @fallback_bind ) = _fallback_where_sql($dbh, $args);
    if ($fallback_sql) {
        push @or,   $fallback_sql;
        push @bind, @fallback_bind;
    }

    return unless @or;
    return ( '(' . join( ' OR ', @or ) . ')', @bind );
}

sub _fallback_where_sql {
    my ( $dbh, $args ) = @_;

    my $query = $args->{query};
    my %selected = map { $_ => 1 } @{ $args->{fields} };
    my @or;
    my @bind;

    if ( $selected{borrowernumber} && $query =~ /^\d+$/ ) {
        push @or,   'b.borrowernumber = ?';
        push @bind, $query;
    }

    for my $field (qw(cardnumber userid)) {
        next unless $selected{$field};
        push @or,   _borrower_field( $dbh, $field ) . ' = ?';
        push @bind, $query;
        push @or,   _borrower_field( $dbh, $field ) . ' LIKE ?';
        push @bind, "$query%";
    }

    for my $field (qw(dateofbirth dateenrolled dateexpiry branchcode categorycode)) {
        next unless $selected{$field};
        push @or,   _borrower_field( $dbh, $field ) . ' = ?';
        push @bind, $query;
    }

    if ( $args->{fallback_like} ) {
        my $like = ( $args->{search_type} // q{} ) eq 'contains' ? "%$query%" : "$query%";
        for my $field ( grep { $FULLTEXT_FIELDS{$_} } @{ $args->{fields} } ) {
            push @or,   _borrower_field( $dbh, $field ) . ' LIKE ?';
            push @bind, $like;
        }
    }

    return unless @or;
    return ( '(' . join( ' OR ', @or ) . ')', @bind );
}

sub _score_sql {
    my ( $dbh, $args ) = @_;

    my $query = $args->{query};
    return ( '0', () ) unless defined $query && length $query;

    my @score;
    my @bind;

    if ( @{ $args->{search_groups} } ) {
        my $fulltext_mode_sql = _fulltext_mode_sql( $args->{match_mode} );
        my $group_sql = join( ',', ('?') x @{ $args->{search_groups} } );
        push @score, qq{
            (
                COALESCE((
                    SELECT MAX(
                        MATCH(pns_score.content) AGAINST (? $fulltext_mode_sql)
                        * CASE
                            WHEN pns_score.field_group LIKE '\\_ATTR\\_%%' THEN 4
                            WHEN pns_score.field_group = 'standard' THEN 5
                            WHEN pns_score.field_group = 'all' THEN 4
                            WHEN pns_score.field_group = 'full_address' THEN 2
                            WHEN pns_score.field_group = 'all_emails' THEN 3
                            WHEN pns_score.field_group = 'all_phones' THEN 3
                            ELSE 1
                          END
                    )
                    FROM @{[ $dbh->quote_identifier($INDEX_TABLE) ]} pns_score
                    WHERE pns_score.borrowernumber = b.borrowernumber
                      AND pns_score.field_group IN ($group_sql)
                ), 0)
            )
        };
        push @bind, $query, @{ $args->{search_groups} };
    }

    my ( $exact_score_sql, @exact_score_bind ) = _exact_score_sql($dbh, $args);
    if ($exact_score_sql) {
        push @score, $exact_score_sql;
        push @bind,  @exact_score_bind;
    }

    return @score ? ( join( ' + ', @score ), @bind ) : ( '0', () );
}

sub _exact_score_sql {
    my ( $dbh, $args ) = @_;

    my $query = $args->{query};
    my %selected = map { $_ => 1 } @{ $args->{fields} };
    my @score;
    my @bind;

    if ( $selected{borrowernumber} && $query =~ /^\d+$/ ) {
        push @score, 'CASE WHEN b.borrowernumber = ? THEN 500 ELSE 0 END';
        push @bind, $query;
    }

    for my $field (qw(cardnumber userid)) {
        next unless $selected{$field};
        push @score, sprintf(
            'CASE WHEN %s = ? THEN 300 WHEN %s LIKE ? THEN 100 ELSE 0 END',
            _borrower_field( $dbh, $field ),
            _borrower_field( $dbh, $field )
        );
        push @bind, $query, "$query%";
    }

    return unless @score;
    return ( '(' . join( ' + ', @score ) . ')', @bind );
}

sub _restricted_branchcodes {
    my ($c) = @_;

    my $user = $c->stash('koha.user');
    if ( !$user ) {
        my $userenv = C4::Context->userenv;
        $user = Koha::Patrons->find( $userenv->{number} )
            if $userenv && $userenv->{number};
    }

    return unless $user;
    return $user->libraries_where_can_see_patrons;
}

sub _add_simple_filter {
    my ( $where, $bind, $column, $value ) = @_;

    $value = _dt_filter_value($value);
    return unless length $value;

    push @{$where}, "$column = ?";
    push @{$bind},  $value;
    return;
}

sub _add_like_filter {
    my ( $where, $bind, $column, $value ) = @_;

    $value = _dt_filter_value($value);
    return unless length $value;

    push @{$where}, "$column LIKE ?";
    push @{$bind},  "%$value%";
    return;
}

sub _add_multi_like_filter {
    my ( $where, $bind, $columns, $value ) = @_;

    $value = _dt_filter_value($value);
    return unless length $value;

    push @{$where}, '(' . join( ' OR ', map { "$_ LIKE ?" } @{$columns} ) . ')';
    push @{$bind},  map { "%$value%" } @{$columns};
    return;
}

sub _add_attribute_filter {
    my ( $where, $bind, $value ) = @_;

    $value = _dt_filter_value($value);
    return unless length $value;

    push @{$where}, q{
        EXISTS (
            SELECT 1
            FROM borrower_attributes ba_column_filter
            LEFT JOIN borrower_attribute_types bat_column_filter
              ON bat_column_filter.code = ba_column_filter.code
            WHERE ba_column_filter.borrowernumber = b.borrowernumber
              AND (
                   ba_column_filter.code LIKE ?
                OR ba_column_filter.attribute LIKE ?
                OR bat_column_filter.description LIKE ?
              )
        )
    };
    push @{$bind}, ( "%$value%" ) x 3;
    return;
}

sub _dt_filter_value {
    my ($value) = @_;

    $value = _trim($value);
    $value =~ s/^\^(.*)\$$/$1/;

    return $value;
}

sub _checkouts_filter_sql {
    return q{
        CONCAT(
            (
                SELECT COUNT(*)
                FROM issues issues_overdue_filter
                WHERE issues_overdue_filter.borrowernumber = b.borrowernumber
                  AND issues_overdue_filter.date_due < NOW()
            ),
            ' / ',
            (
                SELECT COUNT(*)
                FROM issues issues_count_filter
                WHERE issues_count_filter.borrowernumber = b.borrowernumber
            )
        )
    };
}

sub _account_balance_filter_sql {
    return q{
        CAST(
            COALESCE(
                (
                    SELECT SUM(accountlines_balance_filter.amountoutstanding)
                    FROM accountlines accountlines_balance_filter
                    WHERE accountlines_balance_filter.borrowernumber = b.borrowernumber
                ),
                0
            ) AS CHAR
        )
    };
}

sub _borrower_field {
    my ( $dbh, $field ) = @_;
    return 'b.' . $dbh->quote_identifier($field);
}

sub _bounded_int {
    my ( $value, $default, $min, $max ) = @_;

    $value = $default unless defined $value && $value =~ /^\d+$/;
    $value = $min if $value < $min;
    $value = $max if $value > $max;

    return 0 + $value;
}

sub _boolean {
    my ($value) = @_;
    return 0 unless defined $value;
    return $value =~ /^(1|true|yes|on)$/i ? 1 : 0;
}

sub _match_mode {
    my ($value) = @_;
    $value = lc _trim( $value // 'natural' );

    return ('natural') unless length $value;
    return ('natural') if $value =~ /^(natural|natural_language|natural-language)$/;
    return ('boolean') if $value =~ /^(boolean|bool)$/;

    return ( 'natural', "Unsupported match_mode '$value' ignored" );
}

sub _fulltext_mode_sql {
    my ($match_mode) = @_;
    return $match_mode && $match_mode eq 'boolean' ? 'IN BOOLEAN MODE' : 'IN NATURAL LANGUAGE MODE';
}

sub _trim {
    my ($value) = @_;
    $value //= q{};
    $value =~ s/^\s+|\s+$//g;
    return $value;
}

sub _uniq {
    my %seen;
    return grep { !$seen{$_}++ } @_;
}

1;
