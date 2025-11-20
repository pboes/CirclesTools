import json

# Read Backers-raw json and extract addresses
with open('backers-raw-201125.json', 'r') as f:
    backers_data = json.load(f)

backers_addresses = [avatar['id'] for avatar in backers_data['data']['Avatar']]

# Write to csv file
with open('backers_201125.csv', 'w') as f:
    f.write('trustee\n')
    for address in backers_addresses:
        f.write(f'{address}\n')

print(f'Wrote {len(backers_addresses)} addresses to backers_201125.csv')

# Read extendedBackers-raw json and extract addresses
with open('extendedBackers-raw-201125.json', 'r') as f:
    extended_data = json.load(f)

extended_addresses = [avatar['id'] for avatar in extended_data['data']['Avatar']]

# Write to csv file
with open('extended_backers_201125.csv', 'w') as f:
    f.write('trustee\n')
    for address in extended_addresses:
        f.write(f'{address}\n')

print(f'Wrote {len(extended_addresses)} addresses to extended_backers_201125.csv')
