# coding=utf-8
# cython: profile=True
from __future__ import division
from __future__ import print_function

from numpy import array
from sol.opt.gurobiwrapper cimport OptimizationGurobi
from sol.topology.topologynx cimport Topology
from sol.path.paths cimport PPTC

from sol.utils import uniq
from sol.utils.const import EpochComposition, Fairness, NODES, LINKS, ERR_UNKNOWN_MODE
from sol.utils.exceptions import CompositionError, InvalidConfigException
from sol.utils.logger import logger


cpdef compose_apps(apps, Topology topo, network_config, epoch_mode=EpochComposition.AVG, fairness=Fairness.WEIGHTED,
                   weights=None):
    """
    Compose multiple applications into a single optimization
    :param apps: a list of App objects
    :param topo: Topology
    :param epoch_mode: how is the objective computed across different epochs.
        Default is the maximum obj function across epochs. See :py:class:`~sol.EpochComposition`
    :param fairness: type of objective composition. See :py:class:`~sol.ComposeMode`
    :param weights: only applies if fairness is WEIGHTED. Higher weight means higher priority
        (only relative to each other). That is if apps have weights 0.5 and 1, app with priority 1
        is given more importance. Setting weights to be equal (both either 0.5 or 1) has no effect on
        fairness
    :return:
    """
    logger.debug("Starting composition")

    # Merge all paths per traffic class into a single object so we can start the optimization
    all_pptc = PPTC()
    for app in apps:
        all_pptc.update(app.pptc)

    # Start the optimization
    opt = OptimizationGurobi(topo, all_pptc)
    # Extract the capacities from all links and nodes
    node_caps = {node: topo.get_resources(node) for node in topo.nodes()}
    link_caps = {link: topo.get_resources(link) for link in topo.links()}

    # Consume network resources. For each resource, generate resource constraints by considering the
    # load imposed by all traffic classes
    rset = set()
    for app in apps:
        rset.update(app.resource_cost.keys())
    for r in rset:
        cost_funcs, modes = zip(*[app.resource_cost[r] for app in apps if r in app.resource_cost])
        assert len(set(modes)) == 1
        mode = modes[0]
        if mode == NODES:
            capacities = {n: node_caps[n][r] for n in node_caps if r in node_caps[n]}
        elif mode == LINKS:
            capacities = {l: link_caps[l][r] for l in link_caps if r in link_caps[l]}
        else:
            raise InvalidConfigException(ERR_UNKNOWN_MODE % ('resource owner', mode))
        opt.consume(all_pptc, r, cost_funcs, capacities, mode)

    # Cap the resources, if caps were given
    if network_config is not None:
        caps = network_config.get_caps()
        if caps is not None:
            logger.debug('Capping resources')
            for r in caps.resources():
                opt.cap(r, caps.caps(r), tcs=None)

    # And add any other constraints the app might desire
    for app in apps:
        opt.add_named_constraints(app)

    # Compute app weights
    if weights is None:
        volumes = array([app.volume() for app in apps])
        weights = 1 - volumes/volumes.sum()
    else:
        assert 0 <= weights <= 1

    # Add objectives
    objs = []
    for app in apps:
        kwargs = app.obj[2].copy()
        kwargs.update(dict(varname=app.name, tcs=app.obj_tc))
        epoch_objs = opt.add_single_objective(app.obj[0], *app.obj[1], **kwargs)
        objs.append(epoch_objs)
    opt.compose_objectives(array(objs), epoch_mode, fairness, weights)
    return opt

