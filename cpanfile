requires 'perl', '5.014000';
requires 'GraphQL', '0.54';
requires 'XSLoader';

on configure => sub {
    requires 'Module::Build', '0.4005';
};

on 'test' => sub {
    requires 'Test::More', '0.98';
    requires 'Test::Deep', '1.205';
    requires 'Test::Exception', '0.43';
};
