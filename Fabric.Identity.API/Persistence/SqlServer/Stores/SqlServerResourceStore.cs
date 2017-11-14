﻿using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Fabric.Identity.API.Persistence.SqlServer.Services;
using IdentityServer4.Models;
using IdentityServer4.Stores;
using Microsoft.EntityFrameworkCore;
using Fabric.Identity.API.Persistence.SqlServer.Mappers;
using IdentityResource = IdentityServer4.Models.IdentityResource;
using ApiResource = IdentityServer4.Models.ApiResource;

namespace Fabric.Identity.API.Persistence.SqlServer.Stores
{
    public class SqlServerResourceStore : IResourceStore
    {
        protected readonly IIdentityDbContext IdentityDbContext;

        public SqlServerResourceStore(IIdentityDbContext identityDbContext)
        {
            IdentityDbContext = identityDbContext;
        }

        public async Task<IEnumerable<IdentityResource>> FindIdentityResourcesByScopeAsync(IEnumerable<string> scopeNames)
        {
            var scopes = scopeNames.ToArray();

            var identityResources = await IdentityDbContext.IdentityResources
                .Where(i => scopes.Contains(i.Name))
                .Include(x => x.IdentityClaims)
                .ToArrayAsync();

            return identityResources.Select(i => i.ToModel());
        }

        public async Task<IEnumerable<ApiResource>> FindApiResourcesByScopeAsync(IEnumerable<string> scopeNames)
        {
            var scopes = scopeNames.ToArray();

            var apiResources = await IdentityDbContext.ApiResources
                .Where(r => scopes.Contains(r.Name))
                .Include(x => x.ApiClaims)
                .ToArrayAsync();

            return apiResources.Select(r => r.ToModel());
        }

        public async Task<ApiResource> FindApiResourceAsync(string name)
        {
            var apiResource = await IdentityDbContext.ApiResources
                .Where(r => r.Name.Equals(name, StringComparison.OrdinalIgnoreCase))
                .Include(x => x.ApiSecrets)
                .Include(x => x.ApiScopes)
                .ThenInclude(s => s.ApiScopeClaims)
                .Include(x => x.ApiClaims)
                .FirstOrDefaultAsync();

            return apiResource?.ToModel();
        }

        public async Task<Resources> GetAllResources()
        {
            var identity = IdentityDbContext.IdentityResources
                .Include(x => x.IdentityClaims);

            var apis = IdentityDbContext.ApiResources
                .Include(x => x.ApiSecrets)
                .Include(x => x.ApiScopes)
                .ThenInclude(s => s.ApiScopeClaims)
                .Include(x => x.ApiClaims);

            var identityResources = await identity.ToArrayAsync();
            var apiResources = await apis.ToArrayAsync();

            var result = new Resources(
                identityResources.Select(x => x.ToModel()),
                apiResources.Select(x => x.ToModel()));

            return result;
        }
    }
}